defmodule EchsCodex.AuthTest do
  use ExUnit.Case, async: true

  alias EchsCodex.Auth

  test "token_expired?/1 returns false for future expiry" do
    token = jwt_with_exp(System.system_time(:second) + 3600)
    refute Auth.token_expired?(token)
  end

  test "token_expired?/1 returns true for past expiry" do
    token = jwt_with_exp(System.system_time(:second) - 3600)
    assert Auth.token_expired?(token)
  end

  test "token_expired?/1 returns true for malformed tokens" do
    assert Auth.token_expired?("not.a.jwt")
  end

  defp jwt_with_exp(exp) do
    payload = Jason.encode!(%{"exp" => exp})
    encoded = Base.url_encode64(payload, padding: false)
    "header.#{encoded}.sig"
  end
end
