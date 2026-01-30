defmodule EchsCore.HistorySanitizer do
  @moduledoc false

  @type history_item :: map()

  @doc """
  Build `function_call_output` items for any prior tool calls that have no output.

  The OpenAI/Codex Responses API requires that every `function_call` in the
  input history has a corresponding `function_call_output` later in the input.
  If the history is missing outputs (for example due to a crash/restart during a
  tool loop), the API will reject the request with a 400.

  This function returns *only* the missing output items so callers can append
  them to the end of the history (which satisfies the "later in the input"
  constraint).
  """
  @spec repair_output_items([history_item()], non_neg_integer()) :: [history_item()]
  def repair_output_items(history_items, now_ms \\ System.system_time(:millisecond))
      when is_list(history_items) and is_integer(now_ms) and now_ms >= 0 do
    output_call_ids =
      history_items
      |> Enum.filter(&(&1["type"] == "function_call_output"))
      |> Enum.map(&(&1["call_id"] || ""))
      |> Enum.filter(&is_binary/1)
      |> MapSet.new()

    history_items
    |> Enum.filter(&(&1["type"] in ["function_call", "local_shell_call"]))
    |> Enum.map(fn item -> {call_id(item), tool_name(item)} end)
    |> Enum.filter(fn {call_id, _name} ->
      is_binary(call_id) and call_id != "" and not MapSet.member?(output_call_ids, call_id)
    end)
    |> Enum.uniq_by(fn {call_id, _name} -> call_id end)
    |> Enum.map(fn {call_id, name} -> build_missing_output_item(call_id, name, now_ms) end)
  end

  defp call_id(%{"call_id" => call_id}) when is_binary(call_id) and call_id != "", do: call_id
  defp call_id(%{"id" => id}) when is_binary(id) and id != "", do: id
  defp call_id(_), do: nil

  defp tool_name(%{"name" => name}) when is_binary(name) and name != "", do: name
  defp tool_name(%{"type" => type}) when is_binary(type), do: type
  defp tool_name(_), do: "tool"

  defp build_missing_output_item(call_id, name, now_ms) do
    %{
      "type" => "function_call_output",
      "call_id" => call_id,
      "output" =>
        "Error: missing tool output for prior call_id=#{call_id} name=#{name}. " <>
          "ECHS repaired history at #{now_ms}ms; treat this tool call as failed and re-run if needed."
    }
  end
end
