defmodule EchsCli.Tui.StdoutGuard.RingHandler do
  @moduledoc """
  An Erlang :logger handler that forwards log events to the StdoutGuard
  process for ring-buffer storage. Allows in-TUI access to recent logs.
  """

  def log(%{msg: msg, level: level, meta: meta}, %{config: %{pid: guard_pid}}) do
    formatted =
      try do
        text =
          case msg do
            {:string, s} -> to_string(s)
            {:report, report} -> inspect(report)
            {fmt, args} when is_list(args) -> :io_lib.format(fmt, args) |> to_string()
            other -> inspect(other)
          end

        ts = Map.get(meta, :time, :erlang.system_time(:microsecond))
        "[#{level}] #{format_time(ts)} #{String.trim(text)}"
      rescue
        _ -> "[#{level}] <format error>"
      end

    send(guard_pid, {:log_event, formatted})
    :ok
  end

  def adding_handler(config), do: {:ok, config}
  def removing_handler(_config), do: :ok
  def changing_config(_action, _old, new), do: {:ok, new}

  defp format_time(ts) when is_integer(ts) do
    micros = rem(ts, 1_000_000)
    secs = div(ts, 1_000_000)
    {{_y, _m, _d}, {h, mi, s}} = :calendar.system_time_to_universal_time(secs, :second)
    :io_lib.format("~2..0B:~2..0B:~2..0B.~6..0B", [h, mi, s, micros]) |> to_string()
  end

  defp format_time(_), do: "??:??:??"
end
