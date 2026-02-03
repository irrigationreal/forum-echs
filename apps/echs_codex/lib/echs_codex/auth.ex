defmodule EchsCodex.Auth do
  @moduledoc """
  Handles Codex authentication - loading tokens from JSON file,
  checking expiration, and refreshing via `codex login status`.
  """

  use Agent

  @auth_agent __MODULE__

  def start_link(opts \\ []) do
    auth_path = Keyword.get(opts, :auth_path, auth_path_from_env() || default_auth_path())

    case auth_from_env() do
      {:ok, auth} ->
        Agent.start_link(fn -> %{auth: auth, path: auth_path, source: :env} end, name: @auth_agent)

      :error ->
        case load_auth(auth_path) do
          {:ok, auth} ->
            Agent.start_link(fn -> %{auth: auth, path: auth_path, source: :file} end,
              name: @auth_agent
            )

          {:error, _reason} ->
            # Start anyway with nil auth - user can refresh
            Agent.start_link(fn -> %{auth: nil, path: auth_path, source: :file} end,
              name: @auth_agent
            )
        end
    end
  end

  def load_auth(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, json} <- Jason.decode(contents),
         {:ok, auth} <- build_auth(json) do
      {:ok, auth}
    end
  end

  def get_auth do
    case Agent.get(@auth_agent, fn %{auth: auth} -> auth end) do
      nil -> raise "Auth not loaded. Please run `codex login` first."
      auth -> auth
    end
  end

  def auth_source do
    Agent.get(@auth_agent, fn state -> Map.get(state, :source, :file) end)
  end

  def get_headers do
    auth = get_auth()

    [
      {"authorization", "Bearer #{auth.access_token}"},
      {"chatgpt-account-id", auth.account_id},
      {"content-type", "application/json"},
      {"accept", "text/event-stream"}
    ]
  end

  def refresh_auth do
    if auth_source() == :env do
      {:error, "auth refresh not supported when using ECHS_CODEX_ACCESS_TOKEN"}
    else
    # Run `codex login status` to refresh the token
    case System.cmd("codex", ["login", "status"], stderr_to_stdout: true) do
      {_, 0} ->
        # Reload from file
        path = Agent.get(@auth_agent, fn %{path: path} -> path end)

        case load_auth(path) do
          {:ok, auth} ->
            Agent.update(@auth_agent, fn state -> %{state | auth: auth} end)
            :ok

          error ->
            error
        end

      {output, code} ->
        {:error, "codex login status failed (#{code}): #{output}"}
    end
    end
  end

  def token_expired?(token) when is_binary(token) do
    case String.split(token, ".") do
      [_, payload, _] ->
        case Base.url_decode64(payload, padding: false) do
          {:ok, json} ->
            case Jason.decode(json) do
              {:ok, %{"exp" => exp}} ->
                # 60 second buffer
                System.system_time(:second) > exp - 60

              _ ->
                true
            end

          _ ->
            true
        end

      _ ->
        true
    end
  end

  defp default_auth_path do
    Path.join([System.get_env("HOME"), ".codex", "auth.json"])
  end

  defp auth_path_from_env do
    env = System.get_env("ECHS_CODEX_AUTH_PATH") || ""
    env = String.trim(env)
    if env == "", do: nil, else: env
  end

  defp auth_from_env do
    access = System.get_env("ECHS_CODEX_ACCESS_TOKEN") || ""
    access = String.trim(access)

    if access == "" do
      :error
    else
      account_id = System.get_env("ECHS_CODEX_ACCOUNT_ID") || ""
      account_id = String.trim(account_id)

      if account_id == "" do
        raise "ECHS_CODEX_ACCOUNT_ID must be set when ECHS_CODEX_ACCESS_TOKEN is provided."
      end

      {:ok, %{access_token: access, refresh_token: nil, id_token: nil, account_id: account_id}}
    end
  end

  defp build_auth(json) do
    auth = %{
      access_token: get_in(json, ["tokens", "access_token"]),
      refresh_token: get_in(json, ["tokens", "refresh_token"]),
      id_token: get_in(json, ["tokens", "id_token"]),
      account_id: get_in(json, ["tokens", "account_id"])
    }

    if present?(auth.access_token) and present?(auth.account_id) do
      {:ok, auth}
    else
      {:error, :missing_credentials}
    end
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false
end
