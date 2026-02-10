defmodule EchsCore.Rune.Schema do
  @moduledoc """
  Canonical Rune schema definition, encoder/decoder, and visibility filtering.

  A rune is the atomic unit of the ECHS 2.0 event model — an immutable,
  typed event record with the following fields:

    * `event_id` — monotonic uint64 assigned on append (nil before append)
    * `rune_id` — globally unique identifier (format: `run_<hex16>`)
    * `conversation_id` — owning conversation
    * `turn_id` — owning turn (nil for session/config/system runes)
    * `agent_id` — originating agent (nil for session-level runes)
    * `kind` — discriminator from the rune_kinds registry
    * `visibility` — `:public`, `:internal`, or `:secret`
    * `ts_ms` — wall-clock milliseconds since epoch
    * `payload` — kind-specific data (map)
    * `tags` — optional list of string tags for filtering

  ## Schema Versioning

  The `schema_version` field tracks the schema format version. Current
  version is 1. When the schema evolves, the version is bumped and
  migration logic is added to `migrate/1`.
  """

  @schema_version 1

  @type visibility :: :public | :internal | :secret
  @type t :: %__MODULE__{
          event_id: non_neg_integer() | nil,
          rune_id: String.t(),
          conversation_id: String.t(),
          turn_id: String.t() | nil,
          agent_id: String.t() | nil,
          kind: String.t(),
          visibility: visibility(),
          ts_ms: non_neg_integer(),
          payload: map(),
          tags: [String.t()],
          schema_version: pos_integer()
        }

  @enforce_keys [:rune_id, :conversation_id, :kind, :visibility, :ts_ms, :payload]
  defstruct [
    :event_id,
    :rune_id,
    :conversation_id,
    :turn_id,
    :agent_id,
    :kind,
    :visibility,
    :ts_ms,
    :payload,
    tags: [],
    schema_version: @schema_version
  ]

  @doc """
  Returns the current schema version.
  """
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc """
  Create a new rune with a generated rune_id and current timestamp.

  ## Options

    * `:event_id` — pre-assigned event_id (usually nil, assigned by writer)
    * `:conversation_id` — required
    * `:kind` — required, must be a registered rune kind
    * `:payload` — required, kind-specific data
    * `:turn_id` — optional
    * `:agent_id` — optional
    * `:visibility` — optional, defaults to kind's default visibility
    * `:tags` — optional list of strings
    * `:ts_ms` — optional, defaults to current wall clock
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    kind = Keyword.fetch!(opts, :kind)
    conversation_id = Keyword.fetch!(opts, :conversation_id)
    payload = Keyword.fetch!(opts, :payload)

    visibility =
      Keyword.get_lazy(opts, :visibility, fn ->
        default_visibility(kind)
      end)

    %__MODULE__{
      event_id: Keyword.get(opts, :event_id),
      rune_id: generate_rune_id(),
      conversation_id: conversation_id,
      turn_id: Keyword.get(opts, :turn_id),
      agent_id: Keyword.get(opts, :agent_id),
      kind: kind,
      visibility: visibility,
      ts_ms: Keyword.get(opts, :ts_ms, System.system_time(:millisecond)),
      payload: payload,
      tags: Keyword.get(opts, :tags, []),
      schema_version: @schema_version
    }
  end

  @doc """
  Encode a rune to a JSON-serializable map.
  """
  @spec encode(t()) :: map()
  def encode(%__MODULE__{} = rune) do
    %{
      "schema_version" => rune.schema_version,
      "event_id" => rune.event_id,
      "rune_id" => rune.rune_id,
      "conversation_id" => rune.conversation_id,
      "turn_id" => rune.turn_id,
      "agent_id" => rune.agent_id,
      "kind" => rune.kind,
      "visibility" => Atom.to_string(rune.visibility),
      "ts_ms" => rune.ts_ms,
      "payload" => rune.payload,
      "tags" => rune.tags
    }
  end

  @doc """
  Encode a rune to a JSON binary.
  """
  @spec encode_json(t()) :: {:ok, binary()} | {:error, term()}
  def encode_json(%__MODULE__{} = rune) do
    Jason.encode(encode(rune))
  end

  @doc """
  Encode a rune to a JSON binary, raising on error.
  """
  @spec encode_json!(t()) :: binary()
  def encode_json!(%__MODULE__{} = rune) do
    Jason.encode!(encode(rune))
  end

  @doc """
  Decode a rune from a JSON-serializable map.
  """
  @spec decode(map()) :: {:ok, t()} | {:error, term()}
  def decode(map) when is_map(map) do
    with {:ok, migrated} <- migrate(map) do
      {:ok,
       %__MODULE__{
         event_id: migrated["event_id"],
         rune_id: migrated["rune_id"],
         conversation_id: migrated["conversation_id"],
         turn_id: migrated["turn_id"],
         agent_id: migrated["agent_id"],
         kind: migrated["kind"],
         visibility: parse_visibility(migrated["visibility"]),
         ts_ms: migrated["ts_ms"],
         payload: migrated["payload"] || %{},
         tags: migrated["tags"] || [],
         schema_version: migrated["schema_version"]
       }}
    end
  end

  @doc """
  Decode a rune from a JSON binary.
  """
  @spec decode_json(binary()) :: {:ok, t()} | {:error, term()}
  def decode_json(json) when is_binary(json) do
    with {:ok, map} <- Jason.decode(json) do
      decode(map)
    end
  end

  @doc """
  Decode a rune from a JSON binary, raising on error.
  """
  @spec decode_json!(binary()) :: t()
  def decode_json!(json) when is_binary(json) do
    case decode_json(json) do
      {:ok, rune} -> rune
      {:error, reason} -> raise "Failed to decode rune: #{inspect(reason)}"
    end
  end

  @doc """
  Filter a list of runes by visibility. Returns only runes visible at
  the given level:

    * `:public` — only public runes
    * `:internal` — public + internal runes
    * `:secret` — all runes (no filtering)
  """
  @spec filter_visibility([t()], visibility()) :: [t()]
  def filter_visibility(runes, :secret), do: runes

  def filter_visibility(runes, :internal) do
    Enum.filter(runes, &(&1.visibility in [:public, :internal]))
  end

  def filter_visibility(runes, :public) do
    Enum.filter(runes, &(&1.visibility == :public))
  end

  @doc """
  Check if a rune kind is registered in the rune_kinds registry.
  """
  @spec valid_kind?(String.t()) :: boolean()
  def valid_kind?(kind) when is_binary(kind) do
    MapSet.member?(registered_kinds(), kind)
  end

  @doc """
  Return the set of all registered rune kind strings.
  """
  @spec registered_kinds() :: MapSet.t(String.t())
  def registered_kinds do
    registry()
    |> Map.get("kinds", %{})
    |> Map.keys()
    |> MapSet.new()
  end

  @doc """
  Return the full rune_kinds registry as a map.
  """
  @spec registry() :: map()
  def registry do
    case :persistent_term.get({__MODULE__, :registry}, nil) do
      nil ->
        reg = load_registry()
        :persistent_term.put({__MODULE__, :registry}, reg)
        reg

      reg ->
        reg
    end
  end

  @doc """
  Get the default visibility for a rune kind.
  """
  @spec default_visibility(String.t()) :: visibility()
  def default_visibility(kind) do
    case get_in(registry(), ["kinds", kind, "visibility_default"]) do
      "internal" -> :internal
      "secret" -> :secret
      _ -> :public
    end
  end

  # -------------------------------------------------------------------
  # Private
  # -------------------------------------------------------------------

  defp generate_rune_id do
    "run_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp parse_visibility("internal"), do: :internal
  defp parse_visibility("secret"), do: :secret
  defp parse_visibility(_), do: :public

  defp migrate(%{"schema_version" => v} = map) when v == @schema_version do
    {:ok, map}
  end

  defp migrate(%{"schema_version" => v}) when is_integer(v) and v > @schema_version do
    {:error, {:unsupported_schema_version, v}}
  end

  defp migrate(map) when is_map(map) do
    # Assume version 1 if not present (forward compatible)
    {:ok, Map.put_new(map, "schema_version", @schema_version)}
  end

  defp load_registry do
    priv_dir = :code.priv_dir(:echs_core)
    path = Path.join(priv_dir, "rune_kinds.json")

    case File.read(path) do
      {:ok, json} ->
        Jason.decode!(json)

      {:error, _} ->
        # Fallback: empty registry (tests may not have priv dir)
        %{"schema_version" => 1, "kinds" => %{}}
    end
  end
end
