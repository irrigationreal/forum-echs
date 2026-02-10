defmodule EchsCore.ToolSystem.RemoteProvider do
  @moduledoc """
  Remote tool execution via HTTP/WebSocket.

  Supports:
  - HTTP request/response tool execution
  - Idempotency keys for safe retries
  - Per-tool auth configuration (via secret refs)
  - Timeout and error handling
  """

  require Logger

  @type remote_config :: %{
          base_url: String.t(),
          auth: auth_config() | nil,
          timeout_ms: non_neg_integer(),
          idempotency: boolean(),
          headers: [{String.t(), String.t()}]
        }

  @type auth_config :: %{
          type: :bearer | :api_key | :basic,
          secret_ref: String.t()
        }

  @type invocation_result :: %{
          status: :ok | :error | :timeout,
          http_status: integer() | nil,
          body: term(),
          duration_ms: non_neg_integer(),
          idempotency_key: String.t() | nil
        }

  @default_timeout 30_000

  @doc """
  Create a remote provider configuration.
  """
  @spec new(String.t(), keyword()) :: remote_config()
  def new(base_url, opts \\ []) do
    %{
      base_url: String.trim_trailing(base_url, "/"),
      auth: Keyword.get(opts, :auth),
      timeout_ms: Keyword.get(opts, :timeout_ms, @default_timeout),
      idempotency: Keyword.get(opts, :idempotency, true),
      headers: Keyword.get(opts, :headers, [])
    }
  end

  @doc """
  Invoke a tool on the remote provider.
  """
  @spec invoke(remote_config(), String.t(), map(), keyword()) :: invocation_result()
  def invoke(config, tool_name, arguments, opts \\ []) do
    url = "#{config.base_url}/tools/#{tool_name}/invoke"
    idempotency_key = if config.idempotency, do: generate_idempotency_key(), else: nil

    headers = build_headers(config, idempotency_key)
    body = Jason.encode!(%{"arguments" => arguments})
    timeout = Keyword.get(opts, :timeout_ms, config.timeout_ms)

    start = System.monotonic_time(:millisecond)

    result =
      try do
        # Use Req or :httpc for HTTP calls
        case do_http_post(url, headers, body, timeout) do
          {:ok, status, resp_body} ->
            duration = System.monotonic_time(:millisecond) - start
            parsed = try_parse_json(resp_body)

            %{
              status: if(status in 200..299, do: :ok, else: :error),
              http_status: status,
              body: parsed,
              duration_ms: duration,
              idempotency_key: idempotency_key
            }

          {:error, reason} ->
            duration = System.monotonic_time(:millisecond) - start
            %{
              status: :error,
              http_status: nil,
              body: %{"error" => inspect(reason)},
              duration_ms: duration,
              idempotency_key: idempotency_key
            }
        end
      catch
        _, _ ->
          duration = System.monotonic_time(:millisecond) - start
          %{status: :timeout, http_status: nil, body: nil, duration_ms: duration, idempotency_key: idempotency_key}
      end

    result
  end

  @doc """
  List tools available from a remote provider.
  """
  @spec list_tools(remote_config()) :: {:ok, [map()]} | {:error, term()}
  def list_tools(config) do
    url = "#{config.base_url}/tools"
    headers = build_headers(config, nil)

    case do_http_get(url, headers, config.timeout_ms) do
      {:ok, status, body} when status in 200..299 ->
        tools = try_parse_json(body)
        {:ok, if(is_list(tools), do: tools, else: Map.get(tools, "tools", []))}

      {:ok, status, body} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- Internal ---

  defp build_headers(config, idempotency_key) do
    base = [{"content-type", "application/json"} | config.headers]

    base = if idempotency_key do
      [{"idempotency-key", idempotency_key} | base]
    else
      base
    end

    if config.auth do
      add_auth_header(base, config.auth)
    else
      base
    end
  end

  defp add_auth_header(headers, %{type: :bearer, secret_ref: ref}) do
    # In production, resolve secret_ref through a secret manager
    token = resolve_secret(ref)
    [{"authorization", "Bearer #{token}"} | headers]
  end

  defp add_auth_header(headers, %{type: :api_key, secret_ref: ref}) do
    key = resolve_secret(ref)
    [{"x-api-key", key} | headers]
  end

  defp add_auth_header(headers, _), do: headers

  defp resolve_secret(ref) do
    # Simple implementation: check env vars
    # In production, this would use a proper secret manager
    System.get_env(ref) || ref
  end

  defp generate_idempotency_key do
    "idk_" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
  end

  defp try_parse_json(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, parsed} -> parsed
      _ -> body
    end
  end

  defp try_parse_json(body), do: body

  defp do_http_post(url, headers, body, timeout) do
    headers_cl = Enum.map(headers, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    request = {
      String.to_charlist(url),
      headers_cl,
      ~c"application/json",
      body
    }

    http_opts = [timeout: timeout, connect_timeout: 5_000]
    opts = [body_format: :binary]

    case :httpc.request(:post, request, http_opts, opts) do
      {:ok, {{_, status, _}, _resp_headers, resp_body}} ->
        {:ok, status, to_string(resp_body)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_http_get(url, headers, timeout) do
    headers_cl = Enum.map(headers, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    request = {String.to_charlist(url), headers_cl}
    http_opts = [timeout: timeout, connect_timeout: 5_000]
    opts = [body_format: :binary]

    case :httpc.request(:get, request, http_opts, opts) do
      {:ok, {{_, status, _}, _resp_headers, resp_body}} ->
        {:ok, status, to_string(resp_body)}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
