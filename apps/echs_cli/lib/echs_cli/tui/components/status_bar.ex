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
end
