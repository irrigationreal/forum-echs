defmodule EchsCli.Tui.Theme do
  @moduledoc """
  Visual constants: colors, icons, spinner frames, and styling for the TUI.
  """

  import Ratatouille.Constants, only: [color: 1]

  # --- Unicode symbols ---

  def sym(:user), do: "▶"
  def sym(:assistant), do: "◆"
  def sym(:tool_call), do: "→"
  def sym(:tool_result), do: "←"
  def sym(:tool_ok), do: "✔"
  def sym(:tool_err), do: "✘"
  def sym(:system), do: "◈"
  def sym(:reasoning), do: "…"
  def sym(:agent_spawn), do: "◆"
  def sym(:agent_down), do: "◇"
  def sym(:thread_active), do: "●"
  def sym(:thread_idle), do: "○"
  def sym(:separator), do: "·"
  def sym(:prompt), do: "❯"
  def sym(:box_tl), do: "╭"
  def sym(:box_tr), do: "╮"
  def sym(:box_bl), do: "╰"
  def sym(:box_br), do: "╯"
  def sym(:box_h), do: "─"
  def sym(:box_v), do: "│"

  # --- Role colors ---

  def role_color(:user), do: color(:green)
  def role_color(:assistant), do: color(:white)
  def role_color(:tool_call), do: color(:yellow)
  def role_color(:tool_result), do: color(:cyan)
  def role_color(:system), do: color(:magenta)
  def role_color(:reasoning), do: color(:blue)
  def role_color(:subagent_spawned), do: color(:magenta)
  def role_color(:subagent_down), do: color(:magenta)
  def role_color(_), do: color(:white)

  # --- Role prefixes ---

  def role_prefix(:user), do: " #{sym(:user)} "
  def role_prefix(:assistant), do: " #{sym(:assistant)} "
  def role_prefix(:tool_call), do: "   #{sym(:tool_call)} "
  def role_prefix(:tool_result), do: "   #{sym(:tool_result)} "
  def role_prefix(:system), do: " #{sym(:system)} "
  def role_prefix(:reasoning), do: " #{sym(:reasoning)} "
  def role_prefix(:subagent_spawned), do: "   #{sym(:agent_spawn)} "
  def role_prefix(:subagent_down), do: "   #{sym(:agent_down)} "
  def role_prefix(_), do: "    "

  # --- Thread status colors ---

  def thread_color(:idle), do: color(:white)
  def thread_color(:running), do: color(:yellow)
  def thread_color(:error), do: color(:red)
  def thread_color(_), do: color(:white)

  # --- Braille spinner (8-frame, smooth) ---

  @spinner_frames ["⣷", "⣯", "⣟", "⡿", "⢿", "⣻", "⣽", "⣾"]

  def spinner_frame(tick) do
    Enum.at(@spinner_frames, rem(tick, length(@spinner_frames)))
  end

  # --- Tool status icons ---

  def tool_status_icon(:pending), do: sym(:reasoning)
  def tool_status_icon(:running), do: nil
  def tool_status_icon(:success), do: sym(:tool_ok)
  def tool_status_icon(:error), do: sym(:tool_err)
  def tool_status_icon(_), do: ""

  # --- Code block styling ---

  def code_border_color, do: color(:cyan)
  def code_text_color, do: color(:cyan)

  # --- Status bar ---

  def brand_color, do: color(:cyan)
  def keybind_color, do: color(:cyan)
  def elapsed_color, do: color(:yellow)
  def usage_color, do: color(:blue)

  # --- Input ---

  def input_prefix_color, do: color(:green)
end
