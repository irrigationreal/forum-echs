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
    System.get_env("ECHS_BIND") || "127.0.0.1"
  end

  @doc "True if this daemon should allow serving without an API token."
  def allow_no_auth? do
    System.get_env("ECHS_ALLOW_NO_AUTH") in ["1", "true", "yes", "on"]
  end

  @doc "Raises on boot if running in prod without an API token (unless explicitly allowed)."
  def validate_auth_configuration! do
    if Mix.env() == :prod and api_token() == nil and not allow_no_auth?() do
      raise "ECHS_API_TOKEN must be set in production (or set ECHS_ALLOW_NO_AUTH=1 to override)"
    end

    :ok
  end

  def api_token do
    case System.get_env("ECHS_API_TOKEN") do
      nil -> nil
      "" -> nil
      token -> String.trim(token)
    end
    |> case do
      "" -> nil
      token -> token
    end
  end

  def require_api_token? do
    Application.get_env(:echs_server, :require_api_token, false)
  end

  def auth_mode_ok? do
    cond do
      api_token() != nil ->
        :ok

      not require_api_token?() ->
        :ok

      allow_no_auth?() ->
        :ok

      true ->
        {:error,
         "ECHS_API_TOKEN is required in this environment (or set ECHS_ALLOW_NO_AUTH=1 to override)"}
    end
  end
end
