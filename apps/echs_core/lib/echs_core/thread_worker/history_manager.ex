defmodule EchsCore.ThreadWorker.HistoryManager do
  @moduledoc """
  History management functions extracted from ThreadWorker.
  Handles API request preparation, history sanitization, tool output
  truncation, upload expansion, and history item append operations.
  """

  require Logger

  alias EchsCore.{Tools, HistorySanitizer, ModelInfo}
  alias EchsCore.Tools.Truncate
  alias EchsCore.ThreadWorker.Config, as: TWConfig
  alias EchsCore.ThreadWorker.Persistence, as: TWPersist

  # Compaction constant: max tokens for user messages in compacted history
  # Matches codex COMPACT_USER_MESSAGE_MAX_TOKENS
  @compact_user_message_max_tokens 20_000

  # -------------------------------------------------------------------
  # API request preparation
  # -------------------------------------------------------------------

  def drop_unsupported_api_tools(tools) when is_list(tools) do
    Enum.reject(tools, fn tool -> TWConfig.tool_key(tool) == "local_shell" end)
  end

  def drop_unsupported_api_tools(other), do: other

  def maybe_repair_missing_tool_outputs(state) do
    repair_items = HistorySanitizer.repair_output_items(state.history_items)

    case repair_items do
      [] ->
        state

      items ->
        Logger.warning(
          "Repairing missing tool outputs thread_id=#{state.thread_id} missing=#{length(items)}"
        )

        append_history_items(state, items)
    end
  end

  def prepare_api_request(state) do
    truncation_policy = ModelInfo.truncation_policy(state.model)

    api_input =
      state.history_items
      |> sanitize_api_history()
      |> maybe_strip_claude_instructions(state.model)
      |> expand_uploads_for_api()
      |> truncate_tool_outputs_for_api(truncation_policy)

    api_tools =
      state.tools
      |> drop_unsupported_api_tools()
      |> ensure_history_tool_specs(api_input, state.model)
      |> TWConfig.uniq_tools()

    tool_allowlist =
      api_tools
      |> Enum.map(&TWConfig.tool_key/1)
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    {api_input, api_tools, tool_allowlist}
  end

  # -------------------------------------------------------------------
  # History sanitization
  # -------------------------------------------------------------------

  def sanitize_api_history(items) when is_list(items) do
    items
    |> Enum.filter(fn item ->
      item["type"] in [
        "message",
        "function_call",
        "function_call_output",
        "custom_tool_call",
        "custom_tool_call_output"
      ]
    end)
    |> drop_orphan_function_call_outputs()
    |> drop_orphan_function_calls()
    |> merge_consecutive_messages()
  end

  def sanitize_api_history(other), do: other

  # -------------------------------------------------------------------
  # Consecutive message merging
  # -------------------------------------------------------------------

  @doc """
  Merge consecutive messages with the same role into a single message.
  This is required because most LLM APIs expect alternating user/assistant
  messages and may fail or return empty responses when given multiple
  consecutive messages from the same role.
  """
  def merge_consecutive_messages(items) when is_list(items) do
    items
    |> Enum.reduce([], fn item, acc ->
      case {acc, item} do
        # First item: just prepend
        {[], _} ->
          [item]

        # Not a message type: just prepend
        {_, %{"type" => type}} when type != "message" ->
          [item | acc]

        # Current item is a message - check if we should merge
        {[prev | rest], %{"type" => "message", "role" => curr_role, "content" => curr_content}} ->
          case prev do
            %{"type" => "message", "role" => prev_role, "content" => prev_content}
            when prev_role == curr_role ->
              # Same role: merge content
              merged_content = merge_message_content(prev_content, curr_content)
              merged = Map.put(prev, "content", merged_content)
              [merged | rest]

            _ ->
              # Different role or previous wasn't a message: just prepend
              [item | acc]
          end

        # Anything else: just prepend
        _ ->
          [item | acc]
      end
    end)
    |> Enum.reverse()
  end

  def merge_consecutive_messages(other), do: other

  defp merge_message_content(prev, curr) when is_list(prev) and is_list(curr) do
    # Add a separator between merged content blocks
    separator = %{"type" => "text", "text" => "\n\n---\n\n"}
    prev ++ [separator] ++ curr
  end

  defp merge_message_content(prev, curr) when is_binary(prev) and is_binary(curr) do
    prev <> "\n\n---\n\n" <> curr
  end

  defp merge_message_content(prev, curr) when is_binary(prev) and is_list(curr) do
    [%{"type" => "text", "text" => prev}, %{"type" => "text", "text" => "\n\n---\n\n"}] ++ curr
  end

  defp merge_message_content(prev, curr) when is_list(prev) and is_binary(curr) do
    prev ++ [%{"type" => "text", "text" => "\n\n---\n\n"}, %{"type" => "text", "text" => curr}]
  end

  defp merge_message_content(_prev, curr), do: curr

  # -------------------------------------------------------------------
  # Tool output truncation
  # -------------------------------------------------------------------

  def truncate_tool_outputs_for_api(items, policy) when is_list(items) do
    Enum.map(items, fn
      %{"type" => "function_call_output", "output" => output} = item ->
        truncated = truncate_tool_output(output, policy)

        if truncated == output do
          item
        else
          Map.put(item, "output", truncated)
        end

      %{"type" => "custom_tool_call_output", "output" => output} = item ->
        truncated = truncate_tool_output(output, policy)

        if truncated == output do
          item
        else
          Map.put(item, "output", truncated)
        end

      item ->
        item
    end)
  end

  def truncate_tool_outputs_for_api(items, _policy), do: items

  def truncate_tool_output(output, policy) when is_binary(output) do
    Truncate.truncate_text(output, policy)
  end

  def truncate_tool_output(nil, _policy), do: ""

  def truncate_tool_output(output, policy) do
    output
    |> encode_tool_output()
    |> Truncate.truncate_text(policy)
  end

  def encode_tool_output(output) do
    cond do
      is_binary(output) ->
        output

      is_nil(output) ->
        ""

      true ->
        try do
          Jason.encode!(output)
        rescue
          _ -> inspect(output)
        end
    end
  end

  # -------------------------------------------------------------------
  # Claude instruction stripping
  # -------------------------------------------------------------------

  def maybe_strip_claude_instructions(items, model) do
    if TWConfig.claude_model?(model) do
      items
    else
      strip_claude_instructions(items)
    end
  end

  def strip_claude_instructions(items) when is_list(items) do
    Enum.map(items, &strip_claude_instructions_item/1)
  end

  def strip_claude_instructions(other), do: other

  def strip_claude_instructions_item(
        %{"type" => "message", "role" => "user", "content" => content} = item
      ) do
    %{item | "content" => strip_claude_instructions_content(content)}
  end

  def strip_claude_instructions_item(item), do: item

  def strip_claude_instructions_content(content) when is_binary(content) do
    strip_claude_marker_text(content)
  end

  def strip_claude_instructions_content(content) when is_list(content) do
    content
    |> Enum.map(&strip_claude_instructions_content_item/1)
    |> Enum.reject(&empty_content_item?/1)
  end

  def strip_claude_instructions_content(other), do: other

  def strip_claude_instructions_content_item(%{"text" => text} = item) when is_binary(text) do
    updated = strip_claude_marker_text(text)

    if updated == text do
      item
    else
      Map.put(item, "text", updated)
    end
  end

  def strip_claude_instructions_content_item(item), do: item

  def empty_content_item?(%{"text" => text}) when is_binary(text) do
    String.trim(text) == ""
  end

  def empty_content_item?(_), do: false

  def strip_claude_marker_text(text) when is_binary(text) do
    Regex.replace(
      ~r/\A<CLAUDE_INSTRUCTIONS>.*?<\/CLAUDE_INSTRUCTIONS>\s*/s,
      text,
      ""
    )
  end

  def strip_claude_marker_text(other), do: other

  # -------------------------------------------------------------------
  # Tool spec management
  # -------------------------------------------------------------------

  def ensure_history_tool_specs(tools, items, model) when is_list(items) do
    used_tools = tool_names_in_history(items)

    existing =
      tools
      |> Enum.map(&TWConfig.tool_key/1)
      |> Enum.filter(&is_binary/1)
      |> MapSet.new()

    missing = MapSet.difference(used_tools, existing)

    extras =
      missing
      |> Enum.map(&tool_spec_for_name(&1, model))
      |> Enum.reject(&is_nil/1)

    tools ++ extras
  end

  def ensure_history_tool_specs(tools, _items, _model), do: tools

  def tool_names_in_history(items) do
    items
    |> Enum.reduce(MapSet.new(), fn
      %{"type" => "function_call", "name" => name}, acc when is_binary(name) and name != "" ->
        MapSet.put(acc, name)

      %{"type" => "custom_tool_call", "name" => name}, acc when is_binary(name) and name != "" ->
        MapSet.put(acc, name)

      _item, acc ->
        acc
    end)
  end

  def tool_spec_for_name(name, model) when is_binary(name) do
    case name do
      "shell_command" -> Tools.Shell.shell_command_spec()
      "shell" -> Tools.Shell.spec()
      "exec_command" -> Tools.Exec.exec_command_spec()
      "write_stdin" -> Tools.Exec.write_stdin_spec()
      "read_file" -> Tools.Files.read_file_spec()
      "list_dir" -> Tools.Files.list_dir_spec()
      "grep_files" -> Tools.Files.grep_files_spec()
      "apply_patch" -> Tools.ApplyPatch.spec(ModelInfo.apply_patch_tool_type(model))
      "view_image" -> Tools.ViewImage.spec()
      "spawn_agent" -> Tools.SubAgent.spawn_spec()
      "send_input" -> Tools.SubAgent.send_spec()
      "wait" -> Tools.SubAgent.wait_spec()
      "close_agent" -> Tools.SubAgent.close_spec()
      "blackboard_write" -> Tools.SubAgent.blackboard_write_spec()
      "blackboard_read" -> Tools.SubAgent.blackboard_read_spec()
      "send_to_agent" -> alias_tool_spec(Tools.SubAgent.send_spec(), name)
      "wait_agents" -> alias_tool_spec(Tools.SubAgent.wait_spec(), name)
      "kill_agent" -> alias_tool_spec(Tools.SubAgent.close_spec(), name)
      _ -> Tools.CodexForum.spec_by_name(name)
    end
  end

  def tool_spec_for_name(_, _model), do: nil

  def alias_tool_spec(spec, name) when is_map(spec) and is_binary(name) do
    Map.put(spec, "name", name)
  end

  # -------------------------------------------------------------------
  # Orphan cleanup
  # -------------------------------------------------------------------

  def drop_orphan_function_call_outputs(items) when is_list(items) do
    call_ids =
      items
      |> Enum.filter(&(&1["type"] in ["function_call", "custom_tool_call"]))
      |> Enum.map(&(&1["call_id"] || &1["id"] || ""))
      |> Enum.filter(&is_binary/1)
      |> MapSet.new()

    Enum.filter(items, fn
      %{"type" => "function_call_output", "call_id" => call_id} when is_binary(call_id) ->
        MapSet.member?(call_ids, call_id)

      %{"type" => "custom_tool_call_output", "call_id" => call_id} when is_binary(call_id) ->
        MapSet.member?(call_ids, call_id)

      _ ->
        true
    end)
  end

  def drop_orphan_function_calls(items) when is_list(items) do
    output_ids =
      items
      |> Enum.filter(&(&1["type"] in ["function_call_output", "custom_tool_call_output"]))
      |> Enum.map(&(&1["call_id"] || ""))
      |> Enum.filter(&is_binary/1)
      |> MapSet.new()

    Enum.filter(items, fn
      %{"type" => "function_call"} = item ->
        call_id = item["call_id"] || item["id"]
        is_binary(call_id) and call_id != "" and MapSet.member?(output_ids, call_id)

      %{"type" => "custom_tool_call"} = item ->
        call_id = item["call_id"] || item["id"]
        is_binary(call_id) and call_id != "" and MapSet.member?(output_ids, call_id)

      _ ->
        true
    end)
  end

  # -------------------------------------------------------------------
  # History item append
  # -------------------------------------------------------------------

  def append_history_items(state, items) when is_list(items) do
    case items do
      [] ->
        state

      _ ->
        next = %{state | history_items: state.history_items ++ items}
        # Use Map.put to handle old states that may lack this field
        next = Map.put(next, :last_activity_at_ms, System.system_time(:millisecond))

        if TWPersist.store_enabled?() do
          _ = EchsStore.append_items(state.thread_id, Map.get(state, :current_message_id), items)
        end

        next
    end
  end

  def append_history_items(state, _items), do: state

  # -------------------------------------------------------------------
  # Upload expansion
  # -------------------------------------------------------------------

  def expand_uploads_for_api(items) when is_list(items) do
    Enum.map(items, &expand_uploads_item/1)
  end

  def expand_uploads_for_api(other), do: other

  def expand_uploads_item(%{"type" => "message"} = item) do
    Map.update(item, "content", [], fn content ->
      Enum.map(content, &expand_uploads_content_item/1)
    end)
  end

  def expand_uploads_item(item), do: item

  def expand_uploads_content_item(%{"type" => "input_image"} = item) do
    upload_id = item["upload_id"]
    image_url = item["image_url"]

    cond do
      is_binary(image_url) and image_url != "" ->
        item

      is_binary(upload_id) and upload_id != "" ->
        case EchsCore.Uploads.image_url(upload_id) do
          {:ok, url} ->
            item
            |> Map.put("image_url", url)
            |> Map.delete("upload_id")

          {:error, reason} ->
            raise "unable to load upload #{upload_id}: #{inspect(reason)}"
        end

      true ->
        item
    end
  end

  def expand_uploads_content_item(item), do: item
end
