defmodule EchsProtocolTest do
  use ExUnit.Case, async: true

  test "module loads" do
    assert Code.ensure_loaded?(EchsProtocol)
  end

  test "openapi spec is present" do
    spec = EchsProtocol.V1.OpenAPI.spec()
    assert is_map(spec)
    assert spec[:openapi] == "3.1.0"
    assert get_in(spec, [:paths, "/v1/threads"])
  end
end
