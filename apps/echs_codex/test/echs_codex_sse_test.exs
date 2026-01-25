defmodule EchsCodex.SSETest do
  use ExUnit.Case, async: true

  alias EchsCodex.SSE

  test "parses a single JSON event" do
    state = SSE.new_state()

    {state, events} = SSE.parse(state, "data: {\"type\":\"a\"}\n\n")

    assert events == [%{"type" => "a"}]
    assert state.buffer == ""
    assert state.data_lines == []
  end

  test "buffers partial lines across chunks" do
    state = SSE.new_state()

    {state, events} = SSE.parse(state, "data: {\"type\":\"a\"")
    assert events == []
    assert state.buffer != ""

    {state, events} = SSE.parse(state, "}\n\n")
    assert events == [%{"type" => "a"}]
    assert state.buffer == ""
    assert state.data_lines == []
  end

  test "parses multiple events in one chunk" do
    state = SSE.new_state()

    chunk = "data: {\"type\":\"a\"}\n\ndata: {\"type\":\"b\"}\n\n"
    {_state, events} = SSE.parse(state, chunk)

    assert events == [%{"type" => "a"}, %{"type" => "b"}]
  end

  test "parses done sentinel" do
    state = SSE.new_state()

    {_state, events} = SSE.parse(state, "data: [DONE]\n\n")
    assert events == [%{"type" => "done"}]
  end

  test "handles CRLF line endings" do
    state = SSE.new_state()

    {_state, events} = SSE.parse(state, "data: {\"type\":\"a\"}\r\n\r\n")
    assert events == [%{"type" => "a"}]
  end
end
