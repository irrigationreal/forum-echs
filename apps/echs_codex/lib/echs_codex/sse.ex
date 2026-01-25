defmodule EchsCodex.SSE do
  @moduledoc """
  Minimal Server-Sent Events (SSE) parser used by `EchsCodex.Responses`.

  Req streams response bodies in arbitrary chunk boundaries, so SSE lines may be
  split across chunks. This module buffers partial lines and only emits events
  once it sees an SSE event boundary (blank line).

  We only care about `data:` lines and treat each completed SSE event payload as:

  - JSON -> decoded map
  - contains `[DONE]` -> `%{"type" => "done"}`
  """

  @type state :: %{
          buffer: binary(),
          # accumulated `data:` lines (reversed)
          data_lines: [binary()]
        }

  @spec new_state() :: state()
  def new_state do
    %{buffer: "", data_lines: []}
  end

  @spec parse(state(), binary()) :: {state(), [map()]}
  def parse(%{buffer: buffer, data_lines: data_lines} = state, chunk) when is_binary(chunk) do
    data = buffer <> chunk
    lines = String.split(data, "\n", trim: false)

    {complete_lines, next_buffer} =
      if String.ends_with?(data, "\n") do
        {lines, ""}
      else
        {Enum.drop(lines, -1), List.last(lines) || ""}
      end

    {events_rev, next_data_lines} =
      Enum.reduce(complete_lines, {[], data_lines}, fn raw_line, {events, acc_lines} ->
        line = String.trim_trailing(raw_line, "\r")

        cond do
          line == "" ->
            case decode_event_payload(acc_lines) do
              {:ok, event} -> {[event | events], []}
              :empty -> {events, []}
              :error -> {events, []}
            end

          String.starts_with?(line, "data:") ->
            payload =
              line
              |> String.replace_prefix("data:", "")
              |> String.trim_leading()

            {events, [payload | acc_lines]}

          true ->
            {events, acc_lines}
        end
      end)

    {%{state | buffer: next_buffer, data_lines: next_data_lines}, Enum.reverse(events_rev)}
  end

  defp decode_event_payload([]), do: :empty

  defp decode_event_payload(data_lines) when is_list(data_lines) do
    payload =
      data_lines
      |> Enum.reverse()
      |> Enum.join("\n")

    cond do
      payload == "" ->
        :empty

      String.contains?(payload, "[DONE]") ->
        {:ok, %{"type" => "done"}}

      true ->
        case Jason.decode(payload) do
          {:ok, %{} = event} -> {:ok, event}
          _ -> :error
        end
    end
  end
end
