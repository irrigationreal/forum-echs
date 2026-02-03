defmodule EchsServer.Conversations do
  @moduledoc false

  alias EchsServer.ConversationEventBuffer

  @default_model "gpt-5.2-codex"
  @default_reasoning "medium"
  @default_coordination "hierarchical"

  def create(params) when is_map(params) do
    conversation_id = params["conversation_id"] || generate_conversation_id()
    config = normalize_config(params)
    now_ms = now_ms()

    attrs = %{
      conversation_id: conversation_id,
      active_thread_id: nil,
      created_at_ms: now_ms,
      last_activity_at_ms: now_ms,
      model: Map.get(config, "model", @default_model),
      reasoning: Map.get(config, "reasoning", @default_reasoning),
      cwd: Map.get(config, "cwd", File.cwd!()),
      instructions: Map.get(config, "instructions", ""),
      tools_json: encode_tools(Map.get(config, "tools")),
      coordination_mode: Map.get(config, "coordination_mode", @default_coordination)
    }

    with {:ok, conversation} <- EchsStore.upsert_conversation(attrs) do
      _ = ConversationEventBuffer.ensure_started(conversation_id)
      {:ok, conversation}
    end
  end

  def list(opts \\ []) do
    if store_enabled?() do
      {:ok, EchsStore.list_conversations(opts)}
    else
      {:ok, []}
    end
  end

  def get(conversation_id) do
    if store_enabled?() do
      EchsStore.get_conversation(conversation_id)
    else
      {:error, :not_found}
    end
  end

  def update(conversation_id, params) when is_binary(conversation_id) do
    if store_enabled?() do
      with {:ok, conversation} <- EchsStore.get_conversation(conversation_id),
           {:ok, updated} <- update_conversation_record(conversation, params) do
        maybe_apply_config_to_active_thread(updated, params)
        {:ok, updated}
      end
    else
      {:error, :not_found}
    end
  end

  def list_sessions(conversation_id) do
    if store_enabled?() do
      {:ok, EchsStore.list_threads_for_conversation(conversation_id)}
    else
      {:ok, []}
    end
  end

  def enqueue_message(conversation_id, content, opts) do
    with {:ok, conversation} <- ensure_conversation(conversation_id),
         {:ok, {thread_id, message_content, compacted}} <-
           ensure_thread_for_message(conversation, content),
         {:ok, message_id} <- enqueue_to_thread(thread_id, message_content, opts) do
      if compacted do
        ConversationEventBuffer.emit(conversation_id, :session_compacted, %{
          conversation_id: conversation_id,
          thread_id: thread_id
        })
      end

      {:ok,
       %{
         conversation_id: conversation_id,
         thread_id: thread_id,
         message_id: message_id,
         compacted: compacted
       }}
    end
  end

  def stream_attach_thread(conversation_id, thread_id) do
    ConversationEventBuffer.attach_thread(conversation_id, thread_id)
  end

  def get_active_thread(conversation_id) do
    with {:ok, conversation} <- ensure_conversation(conversation_id),
         {:ok, thread_id} <- ensure_active_thread(conversation) do
      {:ok, thread_id}
    end
  end

  def list_history(conversation_id, opts) do
    with {:ok, conversation} <- ensure_conversation(conversation_id) do
      threads =
        if store_enabled?() do
          EchsStore.list_threads_for_conversation(conversation.conversation_id)
        else
          []
        end

      redactions? = Keyword.get(opts, :redact?, false)

      items =
        threads
        |> Enum.flat_map(fn thread ->
          case load_history(thread.thread_id, opts) do
            {:ok, history_items} ->
              marker = %{
                "type" => "session_break",
                "thread_id" => thread.thread_id,
                "created_at_ms" => thread.created_at_ms
              }

              if history_items == [] do
                []
              else
                [marker | history_items]
              end

            {:error, _} ->
              []
          end
        end)

      items = maybe_redact_history(items, redactions?)
      total = length(items)
      offset = normalize_offset(Keyword.get(opts, :offset, 0))
      limit = normalize_limit(Keyword.get(opts, :limit, total), total)

      items =
        items
        |> Enum.drop(offset)
        |> Enum.take(limit)

      {:ok,
       %{conversation_id: conversation_id, items: items, total: total, limit: limit, offset: offset}}
    end
  end

  defp normalize_offset(value) when is_integer(value) and value >= 0, do: value
  defp normalize_offset(_), do: 0

  defp normalize_limit(value, _total) when is_integer(value) and value > 0, do: value
  defp normalize_limit(_value, total), do: total

  defp ensure_conversation(conversation_id) do
    if store_enabled?() do
      EchsStore.get_conversation(conversation_id)
    else
      {:error, :not_found}
    end
  end

  defp ensure_thread_for_message(conversation, content) do
    with {:ok, thread_id} <- ensure_active_thread(conversation) do
      compaction = maybe_compact(conversation, thread_id, content)

      case compaction do
        {:ok, ^thread_id, new_content} ->
          {:ok, {thread_id, new_content, false}}

        {:ok, new_thread_id, new_content} ->
          {:ok, {new_thread_id, new_content, true}}
      end
    end
  end

  defp ensure_active_thread(conversation) do
    thread_id = conversation.active_thread_id

    cond do
      is_binary(thread_id) && thread_id != "" ->
        case ensure_thread_loaded(thread_id) do
          :ok ->
            {:ok, thread_id}

          {:error, :not_found} ->
            create_and_attach_thread(conversation)
        end

      true ->
        create_and_attach_thread(conversation)
    end
  end

  defp create_and_attach_thread(conversation) do
    opts = build_thread_opts(conversation)

    case EchsCore.create_thread(opts) do
      {:ok, thread_id} ->
        _ = store_attach_thread(conversation, thread_id)
        {:ok, thread_id}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp store_attach_thread(conversation, thread_id) do
    if store_enabled?() do
      _ = EchsStore.set_thread_conversation(thread_id, conversation.conversation_id)
      _ = EchsStore.update_conversation_active_thread(conversation.conversation_id, thread_id)
    end

    _ = ConversationEventBuffer.ensure_started(conversation.conversation_id)
    ConversationEventBuffer.attach_thread(conversation.conversation_id, thread_id)
  end

  defp enqueue_to_thread(thread_id, content, opts) do
    mode = Keyword.get(opts, :mode, "queue")
    configure = Keyword.get(opts, :configure, %{})
    message_id = Keyword.get(opts, :message_id)

    opts =
      []
      |> Keyword.put(:mode, mode)
      |> Keyword.put(:configure, configure)
      |> maybe_put_kw(:message_id, message_id)

    try do
      case EchsCore.enqueue_message(thread_id, content, opts) do
        {:ok, message_id} ->
          {:ok, message_id}

        {:error, :paused} ->
          {:error, :paused}

        {:error, reason} ->
          {:error, reason}
      end
    catch
      :exit, _ -> {:error, :not_found}
    end
  end

  defp ensure_thread_loaded(thread_id) do
    case safe_get_state(thread_id) do
      {:ok, _} ->
        :ok

      :not_found ->
        case EchsCore.restore_thread(thread_id) do
          {:ok, _} -> :ok
          {:error, :not_found} -> {:error, :not_found}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp load_history(thread_id, opts) do
    limit = Keyword.get(opts, :limit, 5_000)
    offset = normalize_offset(Keyword.get(opts, :offset, 0))

    case safe_get_history(thread_id, offset: offset, limit: limit) do
      {:ok, %{items: items}} -> {:ok, items}
      {:error, :not_found} -> store_load_history(thread_id)
    end
  end

  defp store_load_history(thread_id) do
    if store_enabled?() do
      EchsStore.load_all(thread_id)
    else
      {:error, :not_found}
    end
  end

  defp update_conversation_record(conversation, params) do
    config = normalize_config(params)
    now_ms = now_ms()

    attrs = %{
      conversation_id: conversation.conversation_id,
      active_thread_id: conversation.active_thread_id,
      created_at_ms: conversation.created_at_ms || now_ms,
      last_activity_at_ms: now_ms,
      model: Map.get(config, "model", conversation.model),
      reasoning: Map.get(config, "reasoning", conversation.reasoning),
      cwd: Map.get(config, "cwd", conversation.cwd),
      instructions: Map.get(config, "instructions", conversation.instructions),
      tools_json:
        if Map.has_key?(config, "tools") do
          encode_tools(Map.get(config, "tools"))
        else
          conversation.tools_json
        end,
      coordination_mode: Map.get(config, "coordination_mode", conversation.coordination_mode)
    }

    EchsStore.upsert_conversation(attrs)
  end

  defp maybe_apply_config_to_active_thread(conversation, params) do
    config = normalize_config(params)

    if conversation.active_thread_id && config != %{} do
      configure = Map.drop(config, ["conversation_id"])
      :ok = EchsCore.configure_thread(conversation.active_thread_id, configure)
    end
  end

  defp build_thread_opts(conversation) do
    tools =
      case Jason.decode(conversation.tools_json || "[]") do
        {:ok, list} when is_list(list) and list != [] -> list
        _ -> nil
      end

    opts =
      []
      |> maybe_put_kw(:cwd, conversation.cwd)
      |> maybe_put_kw(:model, conversation.model)
      |> maybe_put_kw(:reasoning, conversation.reasoning)
      |> maybe_put_kw(:instructions, normalize_instructions(conversation.instructions))
      |> maybe_put_kw(:coordination_mode, parse_coordination(conversation.coordination_mode))

    opts =
      case tools do
        nil -> opts
        _ -> Keyword.put(opts, :tools, tools)
      end

    opts
  end

  defp normalize_instructions(nil), do: nil
  defp normalize_instructions(""), do: nil
  defp normalize_instructions(value), do: value

  defp maybe_compact(conversation, thread_id, content) do
    config = compaction_config()

    with {:ok, items} <- store_load_history(thread_id) do
      usage_ratio = usage_ratio_for_thread(thread_id, conversation.model, config.threshold)
      estimated = estimate_context_chars(items) + estimate_content_chars(content)

      cond do
        is_number(usage_ratio) and usage_ratio < config.threshold ->
          {:ok, thread_id, content}

        is_number(usage_ratio) ->
          maybe_compact_with_summary(conversation, thread_id, content, items, config)

        estimated < config.threshold * config.window_chars ->
          {:ok, thread_id, content}

        true ->
          maybe_compact_with_summary(conversation, thread_id, content, items, config)
      end
    else
      _ -> {:ok, thread_id, content}
    end
  end

  defp maybe_compact_with_summary(conversation, thread_id, content, items, config) do
    case build_compaction_message(conversation, items, content, config) do
      {:ok, compacted_content} ->
        case create_and_attach_thread(%{conversation | active_thread_id: nil}) do
          {:ok, new_thread_id} ->
            {:ok, new_thread_id, compacted_content}

          {:error, _} ->
            # Compaction failed — fall back to the original thread so we never
            # leave the conversation pointing at an orphaned/missing thread.
            {:ok, thread_id, content}
        end

      {:error, _} ->
        {:ok, thread_id, content}
    end
  end

  defp build_compaction_message(conversation, items, latest_content, config) do
    transcript = build_transcript(items, config.summary_max_chars)

    summary =
      case compaction_mode(conversation.model) do
        :remote ->
          case EchsCodex.compact(
                 model: conversation.model,
                 instructions: compaction_instructions(),
                 input: transcript
               ) do
            {:ok, %{output: output}} -> output
            {:error, reason} -> {:error, reason}
          end

        :local ->
          case local_compact(conversation, transcript, config.summary_model) do
            {:ok, output} -> output
            {:error, reason} -> {:error, reason}
          end
      end

    case summary do
      {:error, reason} ->
        {:error, reason}

      output ->
        recent_messages = format_recent_messages(items, config.last_messages)
        reasoning = format_recent_reasoning(items, config.last_reasoning)

        message =
          [
            "[CONTEXT SUMMARY]",
            output,
            recent_messages,
            reasoning,
            "\nLatest user message:",
            normalize_content_text(latest_content),
            "\nContinue with the task if there was one in progress."
          ]
          |> Enum.reject(&empty?/1)
          |> Enum.join("\n")

        {:ok, message}
    end
  rescue
    err ->
      {:error, Exception.message(err)}
  end

  defp local_compact(_conversation, transcript, summary_model) do
    {:ok, agent} = Agent.start_link(fn -> "" end)

    on_event = fn event ->
      case event["type"] do
        "response.output_text.delta" ->
          delta = event["delta"] || ""
          Agent.update(agent, fn acc -> acc <> delta end)

        _ ->
          :ok
      end
    end

    input = [
      %{
        "type" => "message",
        "role" => "user",
        "content" => [%{"type" => "text", "text" => transcript}]
      }
    ]

    result =
      if claude_model?(summary_model) do
        EchsClaude.stream_response(
          model: summary_model,
          instructions: compaction_instructions(),
          input: input,
          tools: [],
          reasoning: "none",
          parallel_tool_calls: false,
          on_event: on_event
        )
      else
        EchsCodex.stream_response(
          model: summary_model,
          instructions: compaction_instructions(),
          input: input,
          tools: [],
          reasoning: "none",
          parallel_tool_calls: false,
          on_event: on_event
        )
      end

    output = Agent.get(agent, & &1)
    Agent.stop(agent)

    case result do
      {:ok, _} -> {:ok, output}
      {:error, reason} -> {:error, reason}
    end
  end

  defp compaction_instructions do
    [
      "Summarize the conversation so far for continuity.",
      "Include key decisions, TODOs, file paths, commands run, tool outputs, and open questions.",
      "Keep it concise and structured."
    ]
    |> Enum.join(" ")
  end

  defp claude_model?(model) when is_binary(model) do
    normalized = model |> String.trim() |> String.downcase()
    normalized in ["opus", "sonnet", "haiku"] or String.starts_with?(normalized, "claude-")
  end

  defp claude_model?(_), do: false

  defp build_transcript(items, max_chars) do
    text =
      items
      |> Enum.map(&format_item/1)
      |> Enum.reject(&empty?/1)
      |> Enum.join("\n\n")

    if String.length(text) > max_chars do
      String.slice(text, 0, max_chars) <> "\n\n[CONTEXT TRUNCATED]"
    else
      text
    end
  end

  defp format_item(%{"type" => "message", "role" => role, "content" => content}) do
    text = extract_text_content(content)
    label = role |> to_string() |> String.upcase()
    "#{label}: #{text}"
  end

  defp format_item(%{"type" => "function_call", "name" => name, "arguments" => args}) do
    "TOOL_CALL: #{name} #{format_args(args)}"
  end

  defp format_item(%{"type" => "local_shell_call", "action" => %{"command" => command}}) do
    "TOOL_CALL: local_shell #{Enum.join(List.wrap(command), " ")}"
  end

  defp format_item(%{"type" => "function_call_output", "output" => output}) do
    "TOOL_RESULT: #{truncate_text(output, 1000)}"
  end

  defp format_item(%{"type" => "reasoning"} = item) do
    summary = reasoning_text(item)
    if summary == "", do: nil, else: "REASONING: #{summary}"
  end

  defp format_item(_), do: nil

  defp format_args(args) when is_binary(args), do: truncate_text(args, 500)
  defp format_args(args) when is_map(args), do: truncate_text(Jason.encode!(args), 500)
  defp format_args(_), do: ""

  defp truncate_text(text, max) when is_binary(text) do
    if String.length(text) > max do
      String.slice(text, 0, max) <> "…"
    else
      text
    end
  end

  defp truncate_text(_text, _max), do: ""

  defp extract_text_content(content) when is_list(content) do
    content
    |> Enum.map(&extract_text_content/1)
    |> Enum.reject(&empty?/1)
    |> Enum.join(" ")
  end

  defp extract_text_content(%{"type" => "text", "text" => text}) when is_binary(text), do: text
  defp extract_text_content(%{"text" => text}) when is_binary(text), do: text
  defp extract_text_content(_), do: ""

  defp reasoning_text(%{"summary" => summary}), do: reasoning_text(summary)
  defp reasoning_text(%{"text" => text}) when is_binary(text), do: text
  defp reasoning_text(summary) when is_binary(summary), do: summary

  defp reasoning_text(summary) when is_list(summary),
    do: Enum.map_join(summary, "", &reasoning_text/1)

  defp reasoning_text(_), do: ""

  defp format_recent_messages(items, count) when count > 0 do
    messages =
      items
      |> Enum.filter(fn
        %{"type" => "message", "role" => role} when role in ["user", "assistant"] -> true
        _ -> false
      end)
      |> Enum.take(-count)
      |> Enum.map(fn %{"role" => role, "content" => content} ->
        text = truncate_text(extract_text_content(content), 1000)
        "#{String.upcase(to_string(role))}: #{text}"
      end)

    if messages == [] do
      nil
    else
      ["[RECENT MESSAGES]", Enum.join(messages, "\n\n")] |> Enum.join("\n")
    end
  end

  defp format_recent_messages(_items, _count), do: nil

  defp format_recent_reasoning(items, count) when count > 0 do
    reasoning =
      items
      |> Enum.filter(fn
        %{"type" => "reasoning"} -> true
        _ -> false
      end)
      |> Enum.take(-count)
      |> Enum.map(fn item -> reasoning_text(item) end)
      |> Enum.reject(&empty?/1)

    if reasoning == [] do
      nil
    else
      ["[RECENT REASONING]", Enum.join(reasoning, "\n")] |> Enum.join("\n")
    end
  end

  defp format_recent_reasoning(_items, _count), do: nil

  defp estimate_context_chars(items) do
    Enum.reduce(items, 0, fn item, acc ->
      acc + estimate_item_chars(item)
    end)
  end

  defp estimate_item_chars(%{"type" => "message", "content" => content}) do
    String.length(extract_text_content(content))
  end

  defp estimate_item_chars(%{"type" => "function_call", "arguments" => args}) do
    String.length(format_args(args))
  end

  defp estimate_item_chars(%{"type" => "function_call_output", "output" => output}) do
    String.length(truncate_text(to_string(output), 2000))
  end

  defp estimate_item_chars(%{"type" => "reasoning"} = item) do
    String.length(reasoning_text(item))
  end

  defp estimate_item_chars(_), do: 0

  defp estimate_content_chars(content) when is_binary(content), do: String.length(content)

  defp estimate_content_chars(content) when is_list(content) do
    content
    |> Enum.map(fn
      %{"text" => text} -> String.length(to_string(text))
      other -> String.length(inspect(other))
    end)
    |> Enum.sum()
  end

  defp estimate_content_chars(_), do: 0

  defp normalize_content_text(content) when is_binary(content), do: content
  defp normalize_content_text(content) when is_list(content), do: inspect(content)
  defp normalize_content_text(other), do: to_string(other)

  defp compaction_mode(model) when is_binary(model) do
    cond do
      String.starts_with?(model, "gpt-") -> :remote
      model in ["opus", "sonnet", "haiku"] -> :local
      true -> :local
    end
  end

  defp compaction_config do
    %{
      window_chars: env_int("ECHS_CONTEXT_WINDOW_CHARS", 200_000),
      threshold: env_float("ECHS_COMPACTION_THRESHOLD", 0.95),
      summary_model: System.get_env("ECHS_COMPACTION_SUMMARY_MODEL") || "haiku",
      summary_max_chars: env_int("ECHS_COMPACTION_MAX_SOURCE_CHARS", 120_000),
      last_messages: env_int("ECHS_COMPACTION_LAST_MESSAGES", 3),
      last_reasoning: env_int("ECHS_COMPACTION_LAST_REASONING", 10)
    }
  end

  defp usage_ratio_for_thread(thread_id, model, _threshold) do
    case safe_get_state(thread_id) do
      {:ok, state} ->
        usage = Map.get(state, :last_usage)
        prompt_tokens = extract_prompt_tokens(usage)
        window = EchsServer.Models.context_window_tokens(model || @default_model)

        if is_integer(prompt_tokens) and window > 0 do
          prompt_tokens / window
        else
          nil
        end

      _ ->
        nil
    end
  end

  defp extract_prompt_tokens(%{} = usage) do
    normalize_int(
      Map.get(usage, "input_tokens") ||
        Map.get(usage, :input_tokens) ||
        Map.get(usage, "prompt_tokens") ||
        Map.get(usage, :prompt_tokens)
    )
  end

  defp extract_prompt_tokens(_), do: nil

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

  defp normalize_config(params) when is_map(params) do
    config = Map.get(params, "config", params)
    stringify_keys(config)
  end

  defp stringify_keys(map) when is_map(map) do
    Enum.reduce(map, %{}, fn {k, v}, acc ->
      Map.put(acc, to_string(k), v)
    end)
  end

  defp stringify_keys(_), do: %{}

  defp encode_tools(nil), do: "[]"

  defp encode_tools(tools) do
    case Jason.encode(tools) do
      {:ok, json} -> json
      _ -> "[]"
    end
  end

  defp parse_coordination(nil), do: nil
  defp parse_coordination("hierarchical"), do: :hierarchical
  defp parse_coordination("blackboard"), do: :blackboard
  defp parse_coordination("peer"), do: :peer
  defp parse_coordination(_), do: nil

  defp maybe_put_kw(opts, _key, nil), do: opts
  defp maybe_put_kw(opts, _key, ""), do: opts
  defp maybe_put_kw(opts, key, value), do: Keyword.put(opts, key, value)

  defp env_int(name, default) do
    case System.get_env(name) do
      nil ->
        default

      "" ->
        default

      value ->
        case Integer.parse(value) do
          {int, _} -> int
          :error -> default
        end
    end
  end

  defp env_float(name, default) do
    case System.get_env(name) do
      nil ->
        default

      "" ->
        default

      value ->
        case Float.parse(value) do
          {float, _} -> float
          :error -> default
        end
    end
  end

  defp now_ms, do: System.system_time(:millisecond)

  defp empty?(value) when value in [nil, ""], do: true
  defp empty?(value) when is_binary(value), do: String.trim(value) == ""
  defp empty?(_), do: false

  defp store_enabled?, do: Code.ensure_loaded?(EchsStore) and EchsStore.enabled?()

  defp safe_get_state(thread_id) do
    try do
      {:ok, EchsCore.get_state(thread_id)}
    catch
      :exit, _ -> :not_found
    end
  end

  defp safe_get_history(thread_id, opts) do
    try do
      EchsCore.get_history(thread_id, opts)
    catch
      :exit, _ -> {:error, :not_found}
    end
  end

  defp maybe_redact_history(items, false), do: items

  defp maybe_redact_history(items, true) when is_list(items) do
    Enum.map(items, &redact_history_item/1)
  end

  defp redact_history_item(item) when is_map(item) do
    case item["type"] do
      "message" ->
        Map.update(item, "content", [], fn content ->
          Enum.map(content, &redact_content_item/1)
        end)

      _ ->
        item
    end
  end

  defp redact_history_item(other), do: other

  defp redact_content_item(%{"type" => "input_image", "image_url" => url} = item)
       when is_binary(url) and url != "" do
    if String.starts_with?(url, "data:") do
      Map.put(item, "image_url", redact_data_url(url))
    else
      item
    end
  end

  defp redact_content_item(item), do: item

  defp redact_data_url(url) do
    case String.split(url, ",", parts: 2) do
      [prefix, _] -> prefix <> ",[redacted]"
      _ -> "data:[redacted]"
    end
  end

  defp generate_conversation_id do
    "conv_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end
end
