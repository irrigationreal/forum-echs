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

    buf2 = %InputBuffer{lines: ["hi", ""]}
    assert InputBuffer.backspace(buf2).lines == ["hi"]
  end

  test "text joins lines and trims" do
    buf = %InputBuffer{lines: ["a", "b"]}
    assert InputBuffer.text(buf) == "a\nb"

    assert InputBuffer.text(%InputBuffer{lines: ["", ""]}) == ""
  end
end
