defmodule EchsCli.Tui.InputBufferTest do
  use ExUnit.Case, async: true

  alias EchsCli.Tui.InputBuffer

  test "append adds characters" do
    buf =
      InputBuffer.new()
      |> InputBuffer.append(?h)
      |> InputBuffer.append(?i)

    assert buf.lines == ["hi"]
  end

  test "newline creates a new line" do
    buf =
      InputBuffer.new()
      |> InputBuffer.append(?h)
      |> InputBuffer.newline()
      |> InputBuffer.append(?i)

    assert buf.lines == ["h", "i"]
  end

  test "backspace removes a character or merges lines" do
    buf =
      InputBuffer.new()
      |> InputBuffer.append(?h)
      |> InputBuffer.append(?i)
      |> InputBuffer.backspace()

    assert buf.lines == ["h"]

    buf2 = %InputBuffer{lines: ["hi", ""], cursor_line: 1, cursor_col: 0}
    result = InputBuffer.backspace(buf2)
    assert result.lines == ["hi"]
    assert result.cursor_line == 0
    assert result.cursor_col == 2
  end

  test "text joins lines and trims" do
    buf = %InputBuffer{lines: ["a", "b"], cursor_line: 0, cursor_col: 0}
    assert InputBuffer.text(buf) == "a\nb"

    assert InputBuffer.text(%InputBuffer{lines: ["", ""], cursor_line: 0, cursor_col: 0}) == ""
  end

  test "move_left moves cursor" do
    buf =
      InputBuffer.new()
      |> InputBuffer.append(?a)
      |> InputBuffer.append(?b)

    assert buf.cursor_col == 2
    buf = InputBuffer.move_left(buf)
    assert buf.cursor_col == 1
    buf = InputBuffer.move_left(buf)
    assert buf.cursor_col == 0
    # At start, should not move further
    buf = InputBuffer.move_left(buf)
    assert buf.cursor_col == 0
  end

  test "move_right moves cursor" do
    buf =
      InputBuffer.new()
      |> InputBuffer.append(?a)
      |> InputBuffer.append(?b)
      |> InputBuffer.move_left()
      |> InputBuffer.move_left()

    assert buf.cursor_col == 0
    buf = InputBuffer.move_right(buf)
    assert buf.cursor_col == 1
    buf = InputBuffer.move_right(buf)
    assert buf.cursor_col == 2
    # At end, should not move further
    buf = InputBuffer.move_right(buf)
    assert buf.cursor_col == 2
  end

  test "insert at cursor position" do
    buf =
      InputBuffer.new()
      |> InputBuffer.append(?a)
      |> InputBuffer.append(?c)
      |> InputBuffer.move_left()
      |> InputBuffer.append(?b)

    assert buf.lines == ["abc"]
    assert buf.cursor_col == 2
  end

  test "move_left wraps to previous line" do
    buf = %InputBuffer{lines: ["ab", "cd"], cursor_line: 1, cursor_col: 0}
    buf = InputBuffer.move_left(buf)
    assert buf.cursor_line == 0
    assert buf.cursor_col == 2
  end

  test "move_right wraps to next line" do
    buf = %InputBuffer{lines: ["ab", "cd"], cursor_line: 0, cursor_col: 2}
    buf = InputBuffer.move_right(buf)
    assert buf.cursor_line == 1
    assert buf.cursor_col == 0
  end
end
