defmodule EchsCore.ThreadWorker.StreamRunner do
  @moduledoc """
  Runs a single streaming API call in a Task process.

  Extracted from ThreadWorker. Contains the streaming request execution,
  SSE event handling, usage extraction, assistant message normalization,
  and stream control polling.

  The GenServer-level stream lifecycle (start/cancel/clear) remains in
  ThreadWorker; this module owns only the Task-side execution.
  """

  require Logger

  alias EchsCore.ThreadWorker.Config, as: TWConfig
  alias EchsCore.ThreadWorker.HistoryManager, as: TWHistory
  alias EchsCore.ThreadWorker.ToolDispatch, as: TWDispatch

  # -------------------------------------------------------------------
  # Stream execution (runs inside a Task)
  # -------------------------------------------------------------------

  @doc """
  Runs a streaming API request. Called from a Task spawned by ThreadWorker.
  Sends `{:stream_complete, stream_ref, result, collected_items}` to parent
  when done.
  """
  def run(state, stream_ref, parent) do
    {:ok, items_agent} = Agent.start_link(fn -> [] end)
    Process.put(:reasoning_delta_seen, false)
    Process.put(:pending_control, nil)
    api_start_ms = System.monotonic_time(:millisecond)

    broadcast_ctx = %{
      thread_id: state.thread_id,
      current_message_id: Map.get(state, :current_message_id)
    }

    {result, collected_items} =
      try do
        on_event = fn event ->
          maybe_send_usage(parent, event)
          handle_sse_event(broadcast_ctx, event, items_agent)
          poll_stream_control()
          maybe_abort_after_event(event)
        end

        {api_input, api_tools, tool_allowlist} = TWHistory.prepare_api_request(state)

        result =
          if TWConfig.claude_model?(state.model) do
            EchsClaude.stream_response(
              model: state.model,
              instructions: state.instructions,
              input: api_input,
              tools: api_tools,
              tool_allowlist: tool_allowlist,
              reasoning: state.reasoning,
              on_event: on_event
            )
          else
            EchsCodex.stream_response(
              model: state.model,
              instructions: state.instructions,
              input: api_input,
              tools: api_tools,
              reasoning: state.reasoning,
              req_opts: codex_req_opts(),
              on_event: on_event
            )
          end

        api_duration_ms = System.monotonic_time(:millisecond) - api_start_ms
        status = if match?({:ok, _}, result), do: :ok, else: :error
        EchsCore.Telemetry.api_request(state.model, status, api_duration_ms)

        {result, Agent.get(items_agent, & &1)}
      catch
        {:stream_control, control} ->
          api_duration_ms = System.monotonic_time(:millisecond) - api_start_ms
          EchsCore.Telemetry.api_request(state.model, :interrupted, api_duration_ms)
          {{:error, control}, Agent.get(items_agent, & &1)}
      after
        Agent.stop(items_agent)
      end

    send(parent, {:stream_complete, stream_ref, result, collected_items})
  end

  # -------------------------------------------------------------------
  # Stream control (called from within the streaming Task)
  # -------------------------------------------------------------------

  @doc false
  def poll_stream_control do
    receive do
      {:stream_control, control} ->
        update_pending_control(control)
        poll_stream_control()
    after
      0 -> :ok
    end
  end

  defp update_pending_control(control) do
    current = Process.get(:pending_control)

    next =
      case {current, control} do
        {nil, new} -> new
        {:interrupt, _} -> :interrupt
        {:pause, :interrupt} -> :interrupt
        {:pause, _} -> :pause
        {:steer, :interrupt} -> :interrupt
        {:steer, :pause} -> :pause
        {:steer, _} -> :steer
        _ -> control
      end

    Process.put(:pending_control, next)
  end

  defp maybe_abort_after_event(event) do
    case Process.get(:pending_control) do
      nil ->
        :ok

      control ->
        if stream_control_boundary?(event) do
          throw({:stream_control, control})
        end
    end
  end

  defp stream_control_boundary?(%{"type" => "response.output_item.done"}), do: true
  defp stream_control_boundary?(%{"type" => "response.completed"}), do: true
  defp stream_control_boundary?(%{"type" => "done"}), do: true
  defp stream_control_boundary?(_), do: false

  # -------------------------------------------------------------------
  # SSE event handling
  # -------------------------------------------------------------------

  @doc false
  def handle_sse_event_for_test(ctx, event, items_agent) do
    handle_sse_event(ctx, event, items_agent)
  end

  defp handle_sse_event(ctx, event, items_agent) do
    maybe_log_sse_event(event)

    case event["type"] do
      "response.output_item.added" ->
        broadcast(ctx, :item_started, %{thread_id: ctx.thread_id, item: event["item"]})

      "response.output_text.delta" ->
        broadcast(ctx, :turn_delta, %{thread_id: ctx.thread_id, content: event["delta"]})

      "response.reasoning_summary.delta" ->
        delta = reasoning_summary_text(event)

        if delta != "" do
          Process.put(:reasoning_delta_seen, true)
          broadcast(ctx, :reasoning_delta, %{thread_id: ctx.thread_id, delta: delta})
        end

      "response.reasoning_summary" ->
        if Process.get(:reasoning_delta_seen) != true do
          summary = reasoning_summary_text(event)

          if summary != "" do
            broadcast(ctx, :reasoning_delta, %{thread_id: ctx.thread_id, delta: summary})
          end
        end

      "response.output_item.done" ->
        item = event["item"]

        if assistant_message?(item) do
          :ok
        else
          broadcast(ctx, :item_completed, %{thread_id: ctx.thread_id, item: item})
          maybe_broadcast_reasoning(ctx, item)
        end

        Agent.update(items_agent, fn items -> items ++ [item] end)

      "response.completed" ->
        :ok

      "done" ->
        :ok

      _ ->
        :ok
    end
  end

  defp maybe_log_sse_event(%{"type" => type} = event) when is_binary(type) do
    if System.get_env("ECHS_SSE_LOG") in ["1", "true", "yes", "on"] do
      summary =
        case type do
          "response.output_text.delta" -> TWDispatch.truncate_event_text(event["delta"])
          "response.reasoning_summary.delta" -> TWDispatch.truncate_event_text(event["delta"])
          "response.output_item.added" -> summarize_item(event["item"])
          "response.output_item.done" -> summarize_item(event["item"])
          _ -> ""
        end

      Logger.info("SSE #{type} #{summary}")
    end
  end

  defp maybe_log_sse_event(_event), do: :ok

  @doc false
  def maybe_broadcast_reasoning(ctx, %{"type" => "reasoning"} = item) do
    summary = reasoning_summary_text(item)

    if summary != "" do
      broadcast(ctx, :reasoning_delta, %{thread_id: ctx.thread_id, delta: summary})
    end
  end

  def maybe_broadcast_reasoning(_ctx, _item), do: :ok

  # -------------------------------------------------------------------
  # Usage extraction
  # -------------------------------------------------------------------

  @doc false
  def maybe_send_usage(parent, %{"type" => "response.completed"} = event) do
    case extract_usage(event) do
      nil -> :ok
      usage -> send(parent, {:usage_update, usage})
    end
  end

  def maybe_send_usage(parent, %{"type" => "message_start"} = event) do
    case extract_usage(event) do
      nil -> :ok
      usage -> send(parent, {:usage_update, usage})
    end
  end

  def maybe_send_usage(parent, %{"type" => "message_delta"} = event) do
    case extract_usage(event) do
      nil -> :ok
      usage -> send(parent, {:usage_update, usage})
    end
  end

  def maybe_send_usage(_parent, _event), do: :ok

  defp extract_usage(%{"response" => %{"usage" => usage}}) when is_map(usage),
    do: normalize_usage(usage)

  defp extract_usage(%{"usage" => usage}) when is_map(usage),
    do: normalize_usage(usage)

  defp extract_usage(_), do: nil

  defp normalize_usage(usage) when is_map(usage) do
    input_tokens =
      normalize_int(
        Map.get(usage, "input_tokens") ||
          Map.get(usage, :input_tokens) ||
          Map.get(usage, "prompt_tokens") ||
          Map.get(usage, :prompt_tokens)
      )

    output_tokens =
      normalize_int(
        Map.get(usage, "output_tokens") ||
          Map.get(usage, :output_tokens) ||
          Map.get(usage, "completion_tokens") ||
          Map.get(usage, :completion_tokens)
      )

    total_tokens =
      normalize_int(Map.get(usage, "total_tokens") || Map.get(usage, :total_tokens)) ||
        case {input_tokens, output_tokens} do
          {input, output} when is_integer(input) and is_integer(output) -> input + output
          _ -> nil
        end

    if input_tokens || output_tokens || total_tokens do
      %{
        "input_tokens" => input_tokens,
        "output_tokens" => output_tokens,
        "total_tokens" => total_tokens
      }
    else
      nil
    end
  end

  defp normalize_usage(_), do: nil

  defp normalize_int(nil), do: nil
  defp normalize_int(value) when is_integer(value), do: value
  defp normalize_int(value) when is_float(value), do: trunc(value)

  defp normalize_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> nil
    end
  end

  defp normalize_int(_), do: nil

  # -------------------------------------------------------------------
  # Assistant message normalization
  # -------------------------------------------------------------------

  @doc "Check if an item is an assistant message."
  def assistant_message?(%{"type" => "message", "role" => "assistant"}), do: true
  def assistant_message?(_), do: false

  @doc """
  Normalize assistant messages in items list. Converts intermediate assistant
  messages to reasoning items. Returns {normalized_items, events}.
  """
  def normalize_assistant_items(items, keep_last_message?) when is_list(items) do
    assistant_indexes =
      items
      |> Enum.with_index()
      |> Enum.filter(fn {item, _idx} -> assistant_message?(item) end)
      |> Enum.map(fn {_item, idx} -> idx end)

    last_index =
      case {keep_last_message?, assistant_indexes} do
        {true, []} -> nil
        {true, _} -> List.last(assistant_indexes)
        _ -> nil
      end

    {normalized_rev, events_rev} =
      items
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {item, idx}, {items_acc, events_acc} ->
        if assistant_message?(item) do
          if keep_last_message? and idx == last_index do
            {[item | items_acc], [{:assistant, item} | events_acc]}
          else
            text = extract_message_text(item)
            reasoning_item = assistant_to_reasoning(item, text)
            {[reasoning_item | items_acc], [{:reasoning, text} | events_acc]}
          end
        else
          {[item | items_acc], events_acc}
        end
      end)

    {Enum.reverse(normalized_rev), Enum.reverse(events_rev)}
  end

  def normalize_assistant_items(items, _keep_last_message?), do: {items, []}

  @doc "Emit assistant/reasoning broadcast events."
  def emit_assistant_events(_ctx, []), do: :ok

  def emit_assistant_events(ctx, events) do
    Enum.each(events, fn
      {:assistant, item} ->
        broadcast(ctx, :item_completed, %{thread_id: ctx.thread_id, item: item})

      {:reasoning, text} ->
        case format_reasoning_delta(text) do
          nil ->
            :ok

          delta ->
            broadcast(ctx, :reasoning_delta, %{thread_id: ctx.thread_id, delta: delta})
        end
    end)
  end

  # -------------------------------------------------------------------
  # Text extraction helpers
  # -------------------------------------------------------------------

  @doc "Extract text content from a message item."
  def extract_message_text(%{"content" => content}), do: extract_text_content(content)
  def extract_message_text(_), do: ""

  @doc "Recursively extract text from content structures."
  def extract_text_content(content) when is_binary(content), do: content

  def extract_text_content(content) when is_list(content) do
    content
    |> Enum.map(&extract_text_content/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  def extract_text_content(%{"type" => "text", "text" => text}) when is_binary(text), do: text
  def extract_text_content(%{"text" => text}) when is_binary(text), do: text
  def extract_text_content(%{"content" => content}), do: extract_text_content(content)
  def extract_text_content(_), do: ""

  @doc "Extract reasoning summary text from an event or item."
  def reasoning_summary_text(%{"delta" => delta}), do: reasoning_summary_text(delta)
  def reasoning_summary_text(%{"summary" => summary}), do: reasoning_summary_text(summary)
  def reasoning_summary_text(%{"text" => text}) when is_binary(text), do: text
  def reasoning_summary_text(summary) when is_binary(summary), do: summary

  def reasoning_summary_text(summary) when is_list(summary) do
    Enum.map_join(summary, "", &reasoning_summary_text/1)
  end

  def reasoning_summary_text(_), do: ""

  # -------------------------------------------------------------------
  # Internal helpers
  # -------------------------------------------------------------------

  defp summarize_item(%{"type" => type} = item) when is_binary(type) do
    case type do
      "function_call" ->
        name = item["name"] || ""
        "tool=#{name}"

      "function_call_output" ->
        "tool_output"

      "message" ->
        role = item["role"] || ""
        text = TWDispatch.truncate_event_text(extract_message_text(item))
        "message role=#{role} text=#{text}"

      _ ->
        "item=#{type}"
    end
  end

  defp summarize_item(_), do: ""

  defp format_reasoning_delta(text) when is_binary(text) do
    trimmed = String.trim(text)
    if trimmed == "", do: nil, else: trimmed <> "\n\n"
  end

  defp format_reasoning_delta(_), do: nil

  defp assistant_to_reasoning(_item, text) do
    %{
      "type" => "reasoning",
      "summary" => text
    }
  end

  defp codex_req_opts do
    case codex_receive_timeout_ms() do
      nil -> []
      timeout_ms -> [receive_timeout: timeout_ms]
    end
  end

  defp codex_receive_timeout_ms do
    case System.get_env("ECHS_CODEX_RECEIVE_TIMEOUT_MS") do
      nil ->
        nil

      value ->
        case Integer.parse(value) do
          {int, _} when int > 0 -> int
          _ -> nil
        end
    end
  end

  defp broadcast(ctx, event_type, data) do
    data =
      if ctx.current_message_id do
        Map.put(data, :message_id, ctx.current_message_id)
      else
        data
      end

    Phoenix.PubSub.broadcast(
      EchsCore.PubSub,
      "thread:#{ctx.thread_id}",
      {event_type, data}
    )
  end
end
