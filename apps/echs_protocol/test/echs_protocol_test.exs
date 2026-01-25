defmodule EchsProtocolTest do
  use ExUnit.Case, async: true

  test "module loads" do
    assert Code.ensure_loaded?(EchsProtocol)
  end
end
