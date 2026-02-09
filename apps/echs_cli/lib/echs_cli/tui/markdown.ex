defmodule EchsCli.Tui.Markdown do
  @moduledoc """
  Simple line-by-line markdown parser that produces styled spans.
  Handles code blocks (``` fences), inline code, bold, and headers.
  Returns `[{:paragraph, [spans]} | {:code_block, content, lang}]`.
  """

  import Ratatouille.Constants, only: [color: 1]

  @type span :: {String.t(), keyword()}
  @type block :: {:paragraph, [span()]} | {:code_block, String.t(), String.t() | nil}

  @doc """
  Parse markdown text into a list of blocks.
  """
  @spec parse(String.t()) :: [block()]
  def parse(text) do
    lines = String.split(text, ~r/\r?\n/, trim: false)
    parse_lines(lines, nil, [], [])
  end

  # --- State machine for code block detection ---

  # Not in a code block
  defp parse_lines([], nil, para_acc, blocks) do
    flush_paragraph(para_acc, blocks)
  end

  defp parse_lines([line | rest], nil, para_acc, blocks) do
    case parse_fence(line) do
      {:open, lang} ->
        blocks = flush_paragraph(para_acc, blocks)
        parse_lines(rest, {lang, []}, [], blocks)

      nil ->
        spans = parse_inline(line)
        parse_lines(rest, nil, para_acc ++ spans ++ [{"\n", []}], blocks)
    end
  end

  # Inside a code block
  defp parse_lines([], {lang, code_acc}, para_acc, blocks) do
    # Unterminated code block - flush as code block anyway
    blocks = flush_paragraph(para_acc, blocks)
    code = Enum.join(Enum.reverse(code_acc), "\n")
    blocks ++ [{:code_block, code, lang}]
  end

  defp parse_lines([line | rest], {lang, code_acc}, para_acc, blocks) do
    if String.match?(line, ~r/^```\s*$/) do
      code = Enum.join(Enum.reverse(code_acc), "\n")
      parse_lines(rest, nil, para_acc, blocks ++ [{:code_block, code, lang}])
    else
      parse_lines(rest, {lang, [line | code_acc]}, para_acc, blocks)
    end
  end

  defp parse_fence(line) do
    case Regex.run(~r/^```(\w*)\s*$/, line) do
      [_, lang] -> {:open, if(lang == "", do: nil, else: lang)}
      _ -> nil
    end
  end

  defp flush_paragraph([], blocks), do: blocks

  defp flush_paragraph(spans, blocks) do
    # Remove trailing newline
    trimmed =
      case List.last(spans) do
        {"\n", _} -> Enum.drop(spans, -1)
        _ -> spans
      end

    if trimmed == [] do
      blocks
    else
      blocks ++ [{:paragraph, trimmed}]
    end
  end

  # --- Inline parsing ---

  @doc """
  Parse a single line into styled spans.
  Handles: `# Header`, `**bold**`, `` `inline code` ``.
  """
  @spec parse_inline(String.t()) :: [span()]
  def parse_inline(line) do
    cond do
      # Headers
      String.match?(line, ~r/^\#{1,3}\s/) ->
        content = String.replace(line, ~r/^\#{1,3}\s+/, "")
        [{content, [attributes: [:bold]]}]

      true ->
        parse_inline_spans(line)
    end
  end

  # Parse inline formatting: **bold** and `code`
  defp parse_inline_spans(text) do
    # Regex to match **bold** or `code` segments
    parts = Regex.split(~r/(\*\*[^*]+\*\*|`[^`]+`)/, text, include_captures: true, trim: false)

    Enum.flat_map(parts, fn part ->
      cond do
        part == "" ->
          []

        String.match?(part, ~r/^\*\*[^*]+\*\*$/) ->
          content = String.slice(part, 2, String.length(part) - 4)
          [{content, [attributes: [:bold]]}]

        String.match?(part, ~r/^`[^`]+`$/) ->
          content = String.slice(part, 1, String.length(part) - 2)
          [{content, [color: color(:cyan)]}]

        true ->
          [{part, []}]
      end
    end)
  end
end
