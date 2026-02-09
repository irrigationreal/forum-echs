defmodule EchsCli.Tui.InputBuffer do
  @moduledoc """
  Input buffer with cursor position tracking for the TUI compose area.
  Supports insert-at-cursor, cursor movement, and visual cursor rendering.
  """

  @type t :: %__MODULE__{
          lines: [String.t()],
          cursor_line: non_neg_integer(),
          cursor_col: non_neg_integer()
        }

  defstruct lines: [""],
            cursor_line: 0,
            cursor_col: 0

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec append(t(), integer() | String.t()) :: t()
  def append(%__MODULE__{} = buf, ch) when is_integer(ch), do: append(buf, <<ch>>)

  def append(%__MODULE__{} = buf, ch) when is_binary(ch) do
    line = Enum.at(buf.lines, buf.cursor_line, "")
    {before, after_cursor} = split_at(line, buf.cursor_col)
    new_line = before <> ch <> after_cursor
    new_col = buf.cursor_col + String.length(ch)

    %{buf | lines: List.replace_at(buf.lines, buf.cursor_line, new_line), cursor_col: new_col}
  end

  @spec newline(t()) :: t()
  def newline(%__MODULE__{} = buf) do
    line = Enum.at(buf.lines, buf.cursor_line, "")
    {before, after_cursor} = split_at(line, buf.cursor_col)

    new_lines =
      buf.lines
      |> List.replace_at(buf.cursor_line, before)
      |> List.insert_at(buf.cursor_line + 1, after_cursor)

    %{buf | lines: new_lines, cursor_line: buf.cursor_line + 1, cursor_col: 0}
  end

  @spec backspace(t()) :: t()
  def backspace(%__MODULE__{cursor_col: 0, cursor_line: 0} = buf), do: buf

  def backspace(%__MODULE__{cursor_col: 0} = buf) do
    prev_line = Enum.at(buf.lines, buf.cursor_line - 1, "")
    curr_line = Enum.at(buf.lines, buf.cursor_line, "")
    merged = prev_line <> curr_line
    new_col = String.length(prev_line)

    new_lines =
      buf.lines
      |> List.delete_at(buf.cursor_line)
      |> List.replace_at(buf.cursor_line - 1, merged)

    %{buf | lines: new_lines, cursor_line: buf.cursor_line - 1, cursor_col: new_col}
  end

  def backspace(%__MODULE__{} = buf) do
    line = Enum.at(buf.lines, buf.cursor_line, "")
    {before, after_cursor} = split_at(line, buf.cursor_col)
    trimmed = String.slice(before, 0, max(0, String.length(before) - 1))
    new_line = trimmed <> after_cursor

    %{buf | lines: List.replace_at(buf.lines, buf.cursor_line, new_line), cursor_col: buf.cursor_col - 1}
  end

  @spec clear(t()) :: t()
  def clear(_buf), do: %__MODULE__{}

  @spec text(t()) :: String.t()
  def text(%__MODULE__{} = buf) do
    buf.lines
    |> Enum.join("\n")
    |> String.trim()
  end

  @spec move_left(t()) :: t()
  def move_left(%__MODULE__{cursor_col: 0, cursor_line: 0} = buf), do: buf

  def move_left(%__MODULE__{cursor_col: 0} = buf) do
    prev_line = Enum.at(buf.lines, buf.cursor_line - 1, "")
    %{buf | cursor_line: buf.cursor_line - 1, cursor_col: String.length(prev_line)}
  end

  def move_left(%__MODULE__{} = buf) do
    %{buf | cursor_col: buf.cursor_col - 1}
  end

  @spec move_right(t()) :: t()
  def move_right(%__MODULE__{} = buf) do
    line = Enum.at(buf.lines, buf.cursor_line, "")
    line_len = String.length(line)

    cond do
      buf.cursor_col < line_len ->
        %{buf | cursor_col: buf.cursor_col + 1}

      buf.cursor_line < length(buf.lines) - 1 ->
        %{buf | cursor_line: buf.cursor_line + 1, cursor_col: 0}

      true ->
        buf
    end
  end

  @spec cursor_position(t(), pos_integer()) :: {non_neg_integer(), non_neg_integer()}
  def cursor_position(%__MODULE__{} = buf, _width) do
    {buf.cursor_line, buf.cursor_col}
  end

  # Split a string at a grapheme position
  defp split_at(str, pos) do
    before = String.slice(str, 0, pos)
    after_part = String.slice(str, pos, String.length(str) - pos)
    {before, after_part}
  end
end
