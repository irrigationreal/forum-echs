defmodule EchsCliTest do
  use ExUnit.Case, async: true

  test "module loads" do
    assert Code.ensure_loaded?(EchsCli)
  end
end
