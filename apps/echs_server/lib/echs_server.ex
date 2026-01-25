defmodule EchsServer do
  @moduledoc """
  Public helpers for the ECHS HTTP daemon.
  """

  def default_port do
    case System.get_env("ECHS_PORT") do
      nil -> 4000
      "" -> 4000
      value -> String.to_integer(value)
    end
  rescue
    _ -> 4000
  end

  def default_bind do
    System.get_env("ECHS_BIND") || "0.0.0.0"
  end

  def api_token do
    case System.get_env("ECHS_API_TOKEN") do
      nil -> nil
      "" -> nil
      token -> token
    end
  end
end
