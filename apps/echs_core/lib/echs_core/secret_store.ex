defmodule EchsCore.SecretStore do
  @moduledoc """
  In-memory secret storage with opaque string references.

  Secrets are stored by reference (e.g. `"secret://api_key_1"`) and never
  exposed in runes, logs, or public-facing data structures. All operations
  redact the actual value from log output.

  ## Reference format

  All references use the `secret://` URI scheme:

      "secret://my_openai_key"
      "secret://tenant_42/anthropic_key"

  ## Environment variable fallback

  When resolving a reference, if no stored value is found, the store falls
  back to checking environment variables. The env var name is derived by
  uppercasing the path component and replacing non-alphanumeric characters
  with underscores:

      "secret://my_api_key" -> checks env var MY_API_KEY

  ## Audit logging

  Every access (store, resolve, delete) is logged via `:telemetry` and
  `Logger` with the secret value redacted.
  """

  use GenServer

  require Logger

  @name __MODULE__
  @prefix "secret://"

  # -------------------------------------------------------------------
  # Types
  # -------------------------------------------------------------------

  @type secret_ref :: String.t()

  @type state :: %{
          secrets: %{optional(secret_ref()) => binary()},
          metadata: %{optional(secret_ref()) => map()}
        }

  # -------------------------------------------------------------------
  # Client API
  # -------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Store a secret value under the given reference.

  The reference must use the `secret://` prefix. Returns `:ok` on success.

  Options:
  - `:description` - human-readable description (stored as metadata)
  - `:tenant_id` - owning tenant
  """
  @spec put(secret_ref(), binary(), keyword()) :: :ok | {:error, :invalid_ref}
  def put(ref, value, opts \\ []) when is_binary(value) do
    if valid_ref?(ref) do
      GenServer.call(@name, {:put, ref, value, opts})
    else
      {:error, :invalid_ref}
    end
  end

  @doc """
  Resolve a secret reference to its value.

  Returns `{:ok, value}` if found in the store or as an environment variable,
  or `{:error, :not_found}` otherwise.

  The resolved value is never logged.
  """
  @spec resolve(secret_ref()) :: {:ok, binary()} | {:error, :not_found}
  def resolve(ref) do
    GenServer.call(@name, {:resolve, ref})
  end

  @doc """
  Delete a secret from the store.
  """
  @spec delete(secret_ref()) :: :ok
  def delete(ref) do
    GenServer.call(@name, {:delete, ref})
  end

  @doc """
  List all stored secret references (values are never returned).
  """
  @spec list() :: [%{ref: secret_ref(), metadata: map()}]
  def list do
    GenServer.call(@name, :list)
  end

  @doc """
  Check whether a reference exists in the store (not counting env fallback).
  """
  @spec exists?(secret_ref()) :: boolean()
  def exists?(ref) do
    GenServer.call(@name, {:exists?, ref})
  end

  @doc """
  Check whether a string looks like a secret reference.
  """
  @spec is_secret_ref?(term()) :: boolean()
  def is_secret_ref?(ref) when is_binary(ref), do: valid_ref?(ref)
  def is_secret_ref?(_), do: false

  @doc """
  Redact all secret references in a string or map, replacing resolved values
  with `"[REDACTED:secret://...]"`.

  This is meant for sanitizing rune content and log output.
  """
  @spec redact(term()) :: term()
  def redact(value) when is_binary(value) do
    Regex.replace(~r/secret:\/\/[A-Za-z0-9_\-\/\.]+/, value, fn match ->
      "[REDACTED:#{match}]"
    end)
  end

  def redact(value) when is_map(value) do
    Map.new(value, fn {k, v} -> {k, redact(v)} end)
  end

  def redact(value) when is_list(value) do
    Enum.map(value, &redact/1)
  end

  def redact(value), do: value

  # -------------------------------------------------------------------
  # GenServer callbacks
  # -------------------------------------------------------------------

  @impl true
  def init(_opts) do
    {:ok,
     %{
       secrets: %{},
       metadata: %{}
     }}
  end

  @impl true
  def handle_call({:put, ref, value, opts}, _from, state) do
    meta = %{
      description: Keyword.get(opts, :description),
      tenant_id: Keyword.get(opts, :tenant_id),
      stored_at: System.system_time(:millisecond)
    }

    state =
      state
      |> put_in([:secrets, ref], value)
      |> put_in([:metadata, ref], meta)

    audit_log(:store, %{ref: ref, tenant_id: meta.tenant_id})
    {:reply, :ok, state}
  end

  def handle_call({:resolve, ref}, _from, state) do
    result =
      case Map.get(state.secrets, ref) do
        nil ->
          # Fallback to environment variable
          env_name = ref_to_env_name(ref)

          case System.get_env(env_name) do
            nil ->
              audit_log(:resolve_miss, %{ref: ref})
              {:error, :not_found}

            env_value ->
              audit_log(:resolve_env, %{ref: ref, env_var: env_name})
              {:ok, env_value}
          end

        value ->
          audit_log(:resolve, %{ref: ref})
          {:ok, value}
      end

    {:reply, result, state}
  end

  def handle_call({:delete, ref}, _from, state) do
    state =
      state
      |> update_in([:secrets], &Map.delete(&1, ref))
      |> update_in([:metadata], &Map.delete(&1, ref))

    audit_log(:delete, %{ref: ref})
    {:reply, :ok, state}
  end

  def handle_call(:list, _from, state) do
    entries =
      Enum.map(state.metadata, fn {ref, meta} ->
        %{ref: ref, metadata: meta}
      end)

    {:reply, entries, state}
  end

  def handle_call({:exists?, ref}, _from, state) do
    {:reply, Map.has_key?(state.secrets, ref), state}
  end

  # -------------------------------------------------------------------
  # Internal
  # -------------------------------------------------------------------

  defp valid_ref?(ref) when is_binary(ref) do
    String.starts_with?(ref, @prefix) and byte_size(ref) > byte_size(@prefix)
  end

  defp ref_to_env_name(ref) do
    ref
    |> String.trim_leading(@prefix)
    |> String.upcase()
    |> String.replace(~r/[^A-Z0-9]/, "_")
  end

  defp audit_log(action, metadata) do
    :telemetry.execute(
      [:echs, :secret, action],
      %{system_time: System.system_time(:millisecond)},
      metadata
    )

    Logger.info("secret_store action=#{action} ref=#{Map.get(metadata, :ref, "n/a")}")
  end
end
