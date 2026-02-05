defmodule EchsCore.Tools.ThreadHistory do
  @moduledoc """
  Tool for recalling history from previous/compacted threads.

  When a conversation is compacted, the old thread ID is preserved.
  This tool allows the agent to query the full history of that thread
  if it needs more context than the summary provides.
  """

  def spec do
    %{
      "type" => "function",
      "name" => "recall_thread_history",
      "description" => """
      Retrieves history items from a previous or compacted thread.
      Use this when you see "[COMPACTED FROM: thr_xxx]" in your context
      and need to recall specific details from the original conversation.
      Returns conversation items (messages, tool calls, tool outputs) in chronological order.
      """,
      "strict" => false,
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "thread_id" => %{
            "type" => "string",
            "description" => "The thread ID to retrieve history from (e.g., thr_abc123)"
          },
          "offset" => %{
            "type" => "integer",
            "description" => "Start from this item index (0-based). Default: 0"
          },
          "limit" => %{
            "type" => "integer",
            "description" => "Maximum number of items to return. Default: 100, max: 500"
          },
          "filter_type" => %{
            "type" => "string",
            "description" =>
              "Optional: filter to specific item types. One of: 'message', 'function_call', 'function_call_output', 'all'. Default: 'all'"
          }
        },
        "required" => ["thread_id"],
        "additionalProperties" => false
      }
    }
  end

  @max_limit 500
  @default_limit 100

  def recall(thread_id, opts \\ []) when is_binary(thread_id) do
    offset = Keyword.get(opts, :offset, 0) |> max(0)
    limit = Keyword.get(opts, :limit, @default_limit) |> min(@max_limit) |> max(1)
    filter_type = Keyword.get(opts, :filter_type, "all")

    case load_thread_history(thread_id, offset, limit) do
      {:ok, items} ->
        filtered = filter_items(items, filter_type)
        format_history(filtered, thread_id, offset, length(items))

      {:error, :not_found} ->
        {:error, "Thread not found: #{thread_id}"}

      {:error, reason} ->
        {:error, "Failed to load thread history: #{inspect(reason)}"}
    end
  end

  defp load_thread_history(thread_id, offset, limit) do
    # Try loading from store first
    if Code.ensure_loaded?(EchsStore) and function_exported?(EchsStore, :get_slice, 3) do
      case EchsStore.get_slice(thread_id, offset, limit) do
        {:ok, %{items: items}} -> {:ok, items}
        {:error, reason} -> {:error, reason}
      end
    else
      # Fallback to in-memory thread if store not available
      case EchsCore.get_history(thread_id, offset: offset, limit: limit) do
        {:ok, %{items: items}} -> {:ok, items}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp filter_items(items, "all"), do: items
  defp filter_items(items, "message"), do: Enum.filter(items, &(&1["type"] == "message"))

  defp filter_items(items, "function_call"),
    do: Enum.filter(items, &(&1["type"] in ["function_call", "local_shell_call"]))

  defp filter_items(items, "function_call_output"),
    do: Enum.filter(items, &(&1["type"] == "function_call_output"))

  defp filter_items(items, _), do: items

  defp format_history(items, thread_id, offset, total_fetched) do
    formatted =
      items
      |> Enum.with_index(offset)
      |> Enum.map(fn {item, idx} -> format_item(item, idx) end)
      |> Enum.join("\n\n---\n\n")

    header = "=== Thread History: #{thread_id} (items #{offset}-#{offset + total_fetched - 1}) ===\n\n"

    {:ok, header <> formatted}
  end

  defp format_item(%{"type" => "message", "role" => role, "content" => content}, idx) do
    text = extract_text(content)
    "[#{idx}] #{String.upcase(role)}:\n#{truncate_text(text, 2000)}"
  end

  defp format_item(%{"type" => "function_call", "name" => name, "arguments" => args}, idx) do
    args_str = if is_binary(args), do: args, else: Jason.encode!(args)
    "[#{idx}] TOOL CALL: #{name}\n#{truncate_text(args_str, 1000)}"
  end

  defp format_item(%{"type" => "local_shell_call", "action" => action}, idx) do
    command = get_in(action, ["command"]) || []
    "[#{idx}] SHELL: #{Enum.join(command, " ")}"
  end

  defp format_item(%{"type" => "function_call_output", "output" => output}, idx) do
    "[#{idx}] TOOL OUTPUT:\n#{truncate_text(to_string(output), 2000)}"
  end

  defp format_item(%{"type" => type} = item, idx) do
    "[#{idx}] #{type}: #{truncate_text(inspect(item), 500)}"
  end

  defp format_item(item, idx) do
    "[#{idx}] #{truncate_text(inspect(item), 500)}"
  end

  defp extract_text(content) when is_binary(content), do: content

  defp extract_text(content) when is_list(content) do
    content
    |> Enum.map(fn
      %{"text" => text} -> text
      %{"type" => "text", "text" => text} -> text
      _ -> ""
    end)
    |> Enum.join("\n")
  end

  defp extract_text(_), do: ""

  defp truncate_text(text, max_len) when byte_size(text) > max_len do
    String.slice(text, 0, max_len) <> "... [truncated]"
  end

  defp truncate_text(text, _), do: text
end
