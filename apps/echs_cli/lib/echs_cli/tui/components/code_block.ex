defmodule EchsCli.Tui.Components.CodeBlock do
  @moduledoc """
  Renders fenced code blocks with rounded Unicode box-drawing borders.
  """

  alias EchsCli.Tui.{Helpers, Theme}

  @doc """
  Render a code block with rounded box-drawing borders.
  Returns a list of label elements.
  """
  @spec render(String.t(), String.t() | nil, non_neg_integer()) :: [Ratatouille.Renderer.Element.t()]
  def render(code, lang, width) do
    border_width = max(1, width - 4)
    h = Theme.sym(:box_h)
    lang_str = if lang && lang != "", do: " #{lang} ", else: ""
    inner_dashes = max(0, border_width - 2 - String.length(lang_str))
    left_dashes = div(inner_dashes, 2)
    right_dashes = inner_dashes - left_dashes

    top_border =
      Theme.sym(:box_tl) <>
        String.duplicate(h, left_dashes) <>
        lang_str <>
        String.duplicate(h, right_dashes) <>
        Theme.sym(:box_tr)

    code_lines = String.split(code, ~r/\r?\n/, trim: false)

    top = Helpers.build_label([{top_border, [color: Theme.code_border_color()]}])

    middle =
      Enum.map(code_lines, fn line ->
        Helpers.build_label([
          {Theme.sym(:box_v), [color: Theme.code_border_color()]},
          {" " <> line, [color: Theme.code_text_color()]}
        ])
      end)

    bottom_border =
      Theme.sym(:box_bl) <>
        String.duplicate(h, max(0, border_width - 2)) <>
        Theme.sym(:box_br)

    bot = Helpers.build_label([{bottom_border, [color: Theme.code_border_color()]}])

    [top] ++ middle ++ [bot]
  end
end
