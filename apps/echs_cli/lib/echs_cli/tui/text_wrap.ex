defmodule EchsCli.Tui.TextWrap do
  @moduledoc """
  Word-boundary text wrapping for both plain strings and styled spans.
  Replaces the grapheme-chunking approach with proper word-boundary breaks.
  """

  @doc """
  Wraps plain text to fit within `width` columns.
  Splits on whitespace boundaries, force-breaking words longer than width.
  Returns a list of strings, one per display line.
  """
  @spec wrap_plain(String.t(), pos_integer()) :: [String.t()]
  def wrap_plain(text, width) when width > 0 do
    text
    |> String.split(~r/\r?\n/, trim: false)
    |> Enum.flat_map(fn line -> wrap_line(line, width) end)
  end

  def wrap_plain(_text, _width), do: [""]

  @doc """
  Wraps a list of styled spans to fit within `width` columns.
  Each span is `{text, style}` where style is a keyword list.
  Returns a list of lines, each a list of `{text, style}` spans.

  ## Example

      iex> wrap_spans([{"hello world", [color: :green]}], 8)
      [[{"hello", [color: :green]}, {" ", [color: :green]}], [{"world", [color: :green]}]]
  """
  @spec wrap_spans([{String.t(), keyword()}], pos_integer()) :: [[{String.t(), keyword()}]]
  def wrap_spans(spans, width) when width > 0 do
    # Tokenize all spans into word/space/newline tokens preserving styles
    tokens = tokenize_spans(spans)
    wrap_tokens(tokens, width)
  end

  def wrap_spans(_spans, _width), do: [[]]

  # --- Plain text line wrapping ---

  defp wrap_line("", _width), do: [""]

  defp wrap_line(line, width) do
    words = String.split(line, ~r/(\s+)/, include_captures: true, trim: false)

    words
    |> Enum.reduce({[], "", 0}, fn segment, {lines, current, col} ->
      seg_len = String.length(segment)

      cond do
        # Whitespace-only segment
        String.match?(segment, ~r/^\s+$/) ->
          if col + seg_len <= width do
            {lines, current <> segment, col + seg_len}
          else
            # Whitespace pushes past width - start new line
            {lines ++ [current], "", 0}
          end

        # Word fits on current line
        col + seg_len <= width ->
          {lines, current <> segment, col + seg_len}

        # Word fits on a fresh line
        seg_len <= width ->
          {lines ++ [current], segment, seg_len}

        # Word is longer than width - must force-break
        true ->
          {broken_lines, remainder, rem_col} =
            force_break_word(segment, width, current, col)

          {lines ++ broken_lines, remainder, rem_col}
      end
    end)
    |> finalize_lines()
  end

  defp force_break_word(word, width, current, col) do
    graphemes = String.graphemes(word)
    do_force_break(graphemes, width, current, col, [])
  end

  defp do_force_break([], _width, current, col, lines) do
    {lines, current, col}
  end

  defp do_force_break([g | rest], width, current, col, lines) do
    if col + 1 > width do
      # current line is full, start new one
      do_force_break([g | rest], width, "", 0, lines ++ [current])
    else
      do_force_break(rest, width, current <> g, col + 1, lines)
    end
  end

  defp finalize_lines({lines, current, _col}) do
    result = lines ++ [current]
    # Ensure at least one line
    if result == [], do: [""], else: result
  end

  # --- Styled span wrapping ---

  defp tokenize_spans(spans) do
    Enum.flat_map(spans, fn {text, style} ->
      # Split on whitespace and newlines, keeping them
      parts = String.split(text, ~r/(\r?\n|\s+)/, include_captures: true, trim: false)

      Enum.map(parts, fn part ->
        cond do
          String.match?(part, ~r/^\r?\n$/) -> {:newline, style}
          String.match?(part, ~r/^\s+$/) -> {:space, part, style}
          part == "" -> nil
          true -> {:word, part, style}
        end
      end)
      |> Enum.reject(&is_nil/1)
    end)
  end

  defp wrap_tokens(tokens, width) do
    {lines, current_line, _col} =
      Enum.reduce(tokens, {[], [], 0}, fn token, {lines, current, col} ->
        case token do
          {:newline, _style} ->
            {lines ++ [current], [], 0}

          {:space, text, style} ->
            space_len = String.length(text)

            if col + space_len <= width do
              {lines, current ++ [{text, style}], col + space_len}
            else
              {lines ++ [current], [], 0}
            end

          {:word, text, style} ->
            word_len = String.length(text)

            cond do
              col + word_len <= width ->
                {lines, current ++ [{text, style}], col + word_len}

              word_len <= width ->
                {lines ++ [current], [{text, style}], word_len}

              true ->
                force_break_styled_word(text, style, width, lines, current, col)
            end
        end
      end)

    result = lines ++ [current_line]

    # Ensure at least one empty line
    if result == [] do
      [[]]
    else
      result
      |> Enum.map(fn line ->
        if line == [], do: [{"", []}], else: line
      end)
    end
  end

  defp force_break_styled_word(word, style, width, lines, current, col) do
    graphemes = String.graphemes(word)

    {result_lines, current_line, current_col} =
      Enum.reduce(graphemes, {lines, current, col}, fn g, {ls, cur, c} ->
        if c + 1 > width do
          {ls ++ [cur], [{g, style}], 1}
        else
          {ls, cur ++ [{g, style}], c + 1}
        end
      end)

    {result_lines, current_line, current_col}
  end
end
