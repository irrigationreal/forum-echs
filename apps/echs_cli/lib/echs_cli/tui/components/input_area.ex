defmodule EchsCli.Tui.Components.InputArea do
  @moduledoc """
  Renders the input compose area with visual cursor using reverse-video.
  """

  alias EchsCli.Tui.{Helpers, Theme}
  alias EchsCli.Tui.InputBuffer
  alias Ratatouille.Renderer.Element

  @input_prefix "❯ "

  @doc """
  Render the input buffer into a list of label elements with visual cursor.
  """
  @spec render(InputBuffer.t(), non_neg_integer(), non_neg_integer()) :: [Element.t()]
  def render(%InputBuffer{} = buf, width, max_height) do
    inner_width = max(1, width - 4)
    prefix = @input_prefix
    prefix_len = String.length(prefix)
    cont_prefix = String.duplicate(" ", prefix_len)

    labels =
      buf.lines
      |> Enum.with_index()
      |> Enum.flat_map(fn {line, line_idx} ->
        pfx = if line_idx == 0, do: prefix, else: cont_prefix
        is_cursor_line = line_idx == buf.cursor_line

        if is_cursor_line do
          render_line_with_cursor(pfx, line, buf.cursor_col, inner_width)
        else
          [render_plain_line(pfx, line, inner_width)]
        end
      end)

    # Trim to max_height (keep tail)
    if length(labels) > max_height do
      Enum.take(labels, -max_height)
    else
      labels
    end
  end

  defp render_line_with_cursor(prefix, line, cursor_col, _width) do
    before = String.slice(line, 0, cursor_col)
    cursor_char = String.at(line, cursor_col) || " "
    after_len = max(0, String.length(line) - cursor_col - 1)
    after_cursor = if after_len > 0, do: String.slice(line, cursor_col + 1, after_len), else: ""

    [
      Helpers.build_label([
        {prefix, [color: Theme.input_prefix_color(), attributes: [:bold]]},
        {before, []},
        {cursor_char, [attributes: [:reverse]]},
        {after_cursor, []}
      ])
    ]
  end

  defp render_plain_line(prefix, line, _width) do
    Helpers.build_label([
      {prefix, [color: Theme.input_prefix_color(), attributes: [:bold]]},
      {line, []}
    ])
  end
end
