defmodule EchsCli.Tui.Components.StatusBar do
  @moduledoc """
  Top and bottom status bars for the TUI.
  Top: branding + thread status + spinner.
  Bottom: keybind help + elapsed time during turns.
  """

  import Ratatouille.View
  alias EchsCli.Tui.{Helpers, Theme}

  @doc """
  Renders the top bar with branding, status, and optional spinner.
  Returns a `bar` element.
  """
  def top_bar(model) do
    thread = Helpers.active_thread(model)

    status_text =
      case thread do
        nil -> ""
        %{status: :running} -> " #{Theme.spinner_frame(model.tick)} Running"
        %{status: :error} -> " #{Theme.sym(:tool_err)}"
        _ -> ""
      end

    bar do
      label do
        text(content: " #{Theme.sym(:assistant)} ECHS ", color: Theme.brand_color(), attributes: [:bold, :reverse])
        text(content: "  #{model.info}#{status_text}", color: Theme.brand_color())
      end
    end
  end

  @doc """
  Renders the bottom bar with keybind help and elapsed time.
  Returns a `bar` element.
  """
  def bottom_bar(model) do
    thread = Helpers.active_thread(model)
    elapsed = format_elapsed(thread)
    usage = format_usage(thread)
    dot = " #{Theme.sym(:separator)} "

    bar do
      label do
        text(content: " Ctrl-N", color: Theme.keybind_color(), attributes: [:bold])
        text(content: " new")
        text(content: dot)
        text(content: "Up/Dn", color: Theme.keybind_color(), attributes: [:bold])
        text(content: " switch")
        text(content: dot)
        text(content: "PgUp/Dn", color: Theme.keybind_color(), attributes: [:bold])
        text(content: " scroll")
        text(content: dot)
        text(content: "Enter", color: Theme.keybind_color(), attributes: [:bold])
        text(content: " send")
        text(content: dot)
        text(content: "Esc", color: Theme.keybind_color(), attributes: [:bold])
        text(content: " quit")
        text(content: elapsed, color: Theme.elapsed_color())
        text(content: usage, color: Theme.usage_color())
      end
    end
  end

  defp format_elapsed(nil), do: ""
  defp format_elapsed(%{turn_started_at: nil}), do: ""

  defp format_elapsed(%{turn_started_at: started, status: :running}) do
    now = System.monotonic_time(:millisecond)
    elapsed_ms = now - started
    secs = div(elapsed_ms, 1000)

    if secs >= 1 do
      "  #{secs}s"
    else
      ""
    end
  end

  defp format_elapsed(_), do: ""

  defp format_usage(nil), do: ""
  defp format_usage(%{usage: nil}), do: ""
  defp format_usage(%{usage: usage}) when is_map(usage) do
    parts = []
    parts = if usage["input_tokens"], do: ["in:#{format_tokens(usage["input_tokens"])}" | parts], else: parts
    parts = if usage["output_tokens"], do: ["out:#{format_tokens(usage["output_tokens"])}" | parts], else: parts

    case parts do
      [] -> ""
      _ -> "  [#{Enum.join(Enum.reverse(parts), " ")}]"
    end
  end
  defp format_usage(_), do: ""

  defp format_tokens(n) when is_integer(n) and n >= 1000, do: "#{Float.round(n / 1000, 1)}k"
  defp format_tokens(n) when is_integer(n), do: "#{n}"
  defp format_tokens(n), do: "#{n}"
end
