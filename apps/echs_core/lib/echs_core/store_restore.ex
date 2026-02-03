defmodule EchsCore.StoreRestore do
  @moduledoc false

  alias EchsCore.ThreadWorker

  @type restore_opt ::
          {:message_limit, pos_integer()}
          | {:history, :all}

  @spec restore_thread(String.t(), [restore_opt()]) :: {:ok, String.t()} | {:error, term()}
  def restore_thread(thread_id, opts \\ []) when is_binary(thread_id) do
    message_limit = Keyword.get(opts, :message_limit, 1_000)

    case Registry.lookup(EchsCore.Registry, thread_id) do
      [{pid, _}] when is_pid(pid) ->
        {:ok, thread_id}

      _ ->
        restore_from_store(thread_id, message_limit)
    end
  end

  defp restore_from_store(thread_id, message_limit) do
    with :ok <- ensure_store_available(),
         {:ok, thread} <- EchsStore.get_thread(thread_id),
         {:ok, history_items} <- EchsStore.load_all(thread_id) do
      auto_resume? = auto_resume_enabled?()

      if not auto_resume? do
        # A daemon restart can leave messages stuck in "running". Mark those as
        # error so status queries stay honest. We do *not* mark queued messages
        # because those can be replayed.
        _ = EchsStore.mark_incomplete_messages(thread_id, include_queued: false)
      end

      messages = EchsStore.list_messages(thread_id, limit: message_limit)

      {message_ids, message_log} = build_message_cache(messages)
      {resume_turns, queued_turns, steer_queue} = build_queues(messages, auto_resume?)

      tools = decode_tools(thread.tools_json)

      create_opts = [
        thread_id: thread.thread_id,
        parent_thread_id: thread.parent_thread_id,
        created_at_ms: thread.created_at_ms,
        last_activity_at_ms: thread.last_activity_at_ms,
        model: thread.model,
        reasoning: thread.reasoning,
        cwd: thread.cwd,
        instructions: thread.instructions,
        tools: tools,
        coordination_mode: parse_coordination(thread.coordination_mode),
        history_items: history_items,
        message_ids: message_ids,
        message_log: message_log,
        queued_turns: queued_turns,
        resume_turns: resume_turns,
        steer_queue: steer_queue
      ]

      case ThreadWorker.create(create_opts) do
        {:ok, ^thread_id} ->
          cleanup_orphaned_children(thread_id)
          {:ok, thread_id}

        {:ok, other_id} ->
          cleanup_orphaned_children(other_id)
          {:ok, other_id}

        {:error, {:already_started, _pid}} ->
          {:ok, thread_id}

        other ->
          other
      end
    end
  end

  # Kill any child threads that survived the parent crash. These orphans are
  # still running under DynamicSupervisor but have no parent monitoring them.
  defp cleanup_orphaned_children(parent_thread_id) do
    Registry.select(EchsCore.Registry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.each(fn {child_id, _pid} ->
      if child_id != parent_thread_id do
        try do
          state = ThreadWorker.get_state(child_id)

          if state.parent_thread_id == parent_thread_id do
            ThreadWorker.kill(child_id)
          end
        catch
          :exit, _ -> :ok
        end
      end
    end)
  end

  defp ensure_store_available do
    if Code.ensure_loaded?(EchsStore) and EchsStore.enabled?() do
      :ok
    else
      {:error, :store_unavailable}
    end
  end

  defp decode_tools(nil), do: []
  defp decode_tools(""), do: []

  defp decode_tools(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, tools} when is_list(tools) -> tools
      _ -> []
    end
  end

  defp decode_tools(other) when is_list(other), do: other
  defp decode_tools(_), do: []

  defp parse_coordination(nil), do: :hierarchical
  defp parse_coordination("hierarchical"), do: :hierarchical
  defp parse_coordination("blackboard"), do: :blackboard
  defp parse_coordination("peer"), do: :peer
  defp parse_coordination(_), do: :hierarchical

  defp build_message_cache(messages) when is_list(messages) do
    sorted =
      Enum.sort_by(messages, fn m ->
        {m.enqueued_at_ms || 0, m.message_id}
      end)

    message_ids = Enum.map(sorted, & &1.message_id)

    message_log =
      Enum.reduce(sorted, %{}, fn msg, acc ->
        meta = %{
          message_id: msg.message_id,
          status: parse_status(msg.status),
          enqueued_at_ms: msg.enqueued_at_ms,
          started_at_ms: msg.started_at_ms,
          completed_at_ms: msg.completed_at_ms,
          history_start: msg.history_start,
          history_end: msg.history_end,
          error: msg.error,
          request_json: msg.request_json
        }

        Map.put(acc, msg.message_id, meta)
      end)

    {message_ids, message_log}
  end

  defp parse_status(nil), do: :queued

  defp parse_status(status) when is_binary(status) do
    case status do
      "queued" -> :queued
      "running" -> :running
      "completed" -> :completed
      "interrupted" -> :interrupted
      "paused" -> :paused
      "error" -> :error
      _ -> :queued
    end
  end

  defp parse_status(_), do: :queued

  defp build_queues(messages, auto_resume?) do
    Enum.reduce(messages, {[], [], []}, fn msg, {resume, queued, steer} ->
      cond do
        auto_resume? and msg.status == "running" and is_binary(msg.request_json) and
            msg.request_json != "" ->
          case decode_request_json(msg.request_json) do
            {:ok, %{content: content, configure: configure}} ->
              opts = [configure: configure]
              enqueued_at_ms = msg.started_at_ms || msg.enqueued_at_ms || System.system_time(:millisecond)

              turn = %{
                from: nil,
                content: content,
                opts: opts,
                message_id: msg.message_id,
                enqueued_at_ms: enqueued_at_ms
              }

              {resume ++ [turn], queued, steer}

            _ ->
              {resume, queued, steer}
          end

        msg.status == "queued" and is_binary(msg.request_json) and msg.request_json != "" ->
          case decode_request_json(msg.request_json) do
            {:ok, %{content: content, configure: configure, mode: mode}} ->
              opts = [configure: configure]

              case mode do
                :steer ->
                  turn = %{
                    from: nil,
                    content: content,
                    opts: Keyword.put(opts, :mode, :steer),
                    message_id: msg.message_id,
                    enqueued_at_ms: msg.enqueued_at_ms || System.system_time(:millisecond),
                    preserve_reply?: false
                  }

                  {resume, queued, steer ++ [turn]}

                :queue ->
                  turn = %{
                    from: nil,
                    content: content,
                    opts: Keyword.put(opts, :mode, :queue),
                    message_id: msg.message_id,
                    enqueued_at_ms: msg.enqueued_at_ms || System.system_time(:millisecond)
                  }

                  {resume, queued ++ [turn], steer}
              end

            _ ->
              {resume, queued, steer}
          end

        true ->
          {resume, queued, steer}
      end
    end)
  end

  defp auto_resume_enabled? do
    case System.get_env("ECHS_AUTO_RESUME") do
      nil -> true
      value -> value in ["1", "true", "yes", "on"]
    end
  end

  defp decode_request_json(json) when is_binary(json) do
    with {:ok, payload} <- Jason.decode(json),
         payload when is_map(payload) <- payload do
      configure =
        case Map.get(payload, "configure") do
          cfg when is_map(cfg) -> cfg
          _ -> %{}
        end

      content =
        cond do
          is_list(payload["content"]) -> payload["content"]
          is_binary(payload["content"]) -> payload["content"]
          true -> ""
        end

      mode =
        case Map.get(payload, "mode") do
          "steer" -> :steer
          :steer -> :steer
          _ -> :queue
        end

      {:ok, %{content: content, configure: configure, mode: mode}}
    else
      _ -> {:error, :invalid_request_json}
    end
  end

  defp decode_request_json(_), do: {:error, :invalid_request_json}
end
