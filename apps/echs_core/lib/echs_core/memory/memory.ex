defmodule EchsCore.Memory.Memory do
  @moduledoc """
  Memory schema and storage layer.

  Memory types:
  - :episodic — specific events/interactions recalled verbatim
  - :semantic — facts, concepts, general knowledge extracted
  - :procedural — how-to knowledge, patterns, workflows
  - :decision — past decisions with rationale and outcome

  Each memory has:
  - content (the knowledge)
  - tags for categorization
  - confidence score (0.0-1.0)
  - source_rune_ids linking back to originating runes
  - privacy level (:public, :internal, :secret)
  """

  @type memory_type :: :episodic | :semantic | :procedural | :decision
  @type privacy :: :public | :internal | :secret

  @type t :: %__MODULE__{
          memory_id: String.t(),
          conversation_id: String.t() | nil,
          memory_type: memory_type(),
          content: String.t(),
          tags: [String.t()],
          confidence: float(),
          source_rune_ids: [String.t()],
          privacy: privacy(),
          created_at_ms: non_neg_integer(),
          updated_at_ms: non_neg_integer(),
          expires_at_ms: non_neg_integer() | nil,
          metadata: map()
        }

  defstruct [
    :memory_id,
    :conversation_id,
    memory_type: :semantic,
    content: "",
    tags: [],
    confidence: 0.5,
    source_rune_ids: [],
    privacy: :internal,
    created_at_ms: 0,
    updated_at_ms: 0,
    expires_at_ms: nil,
    metadata: %{}
  ]

  @doc "Create a new memory with a generated ID."
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    now = System.system_time(:millisecond)

    %__MODULE__{
      memory_id: Keyword.get(opts, :memory_id, generate_id()),
      conversation_id: Keyword.get(opts, :conversation_id),
      memory_type: Keyword.get(opts, :memory_type, :semantic),
      content: Keyword.get(opts, :content, ""),
      tags: Keyword.get(opts, :tags, []),
      confidence: Keyword.get(opts, :confidence, 0.5),
      source_rune_ids: Keyword.get(opts, :source_rune_ids, []),
      privacy: Keyword.get(opts, :privacy, :internal),
      created_at_ms: Keyword.get(opts, :created_at_ms, now),
      updated_at_ms: Keyword.get(opts, :updated_at_ms, now),
      expires_at_ms: Keyword.get(opts, :expires_at_ms),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @doc "Check if a memory has expired."
  @spec expired?(t()) :: boolean()
  def expired?(%__MODULE__{expires_at_ms: nil}), do: false

  def expired?(%__MODULE__{expires_at_ms: exp}) do
    System.system_time(:millisecond) > exp
  end

  @doc "Check if a memory matches the given privacy filter."
  @spec visible?(t(), privacy()) :: boolean()
  def visible?(%__MODULE__{privacy: :public}, _), do: true
  def visible?(%__MODULE__{privacy: :internal}, level) when level in [:internal, :secret], do: true
  def visible?(%__MODULE__{privacy: :secret}, :secret), do: true
  def visible?(_, _), do: false

  @doc "Update confidence score (clamped 0.0-1.0)."
  @spec update_confidence(t(), float()) :: t()
  def update_confidence(%__MODULE__{} = mem, new_confidence) do
    clamped = max(0.0, min(1.0, new_confidence))
    %{mem | confidence: clamped, updated_at_ms: System.system_time(:millisecond)}
  end

  @doc "Add tags to a memory."
  @spec add_tags(t(), [String.t()]) :: t()
  def add_tags(%__MODULE__{} = mem, new_tags) do
    %{mem | tags: Enum.uniq(mem.tags ++ new_tags), updated_at_ms: System.system_time(:millisecond)}
  end

  @doc "Serialize to map for JSON encoding."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = mem) do
    %{
      memory_id: mem.memory_id,
      conversation_id: mem.conversation_id,
      memory_type: Atom.to_string(mem.memory_type),
      content: mem.content,
      tags: mem.tags,
      confidence: mem.confidence,
      source_rune_ids: mem.source_rune_ids,
      privacy: Atom.to_string(mem.privacy),
      created_at_ms: mem.created_at_ms,
      updated_at_ms: mem.updated_at_ms,
      expires_at_ms: mem.expires_at_ms,
      metadata: mem.metadata
    }
  end

  @doc "Deserialize from map."
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %__MODULE__{
      memory_id: map["memory_id"] || map[:memory_id],
      conversation_id: map["conversation_id"] || map[:conversation_id],
      memory_type: parse_atom(map["memory_type"] || map[:memory_type], :semantic),
      content: map["content"] || map[:content] || "",
      tags: map["tags"] || map[:tags] || [],
      confidence: map["confidence"] || map[:confidence] || 0.5,
      source_rune_ids: map["source_rune_ids"] || map[:source_rune_ids] || [],
      privacy: parse_atom(map["privacy"] || map[:privacy], :internal),
      created_at_ms: map["created_at_ms"] || map[:created_at_ms] || 0,
      updated_at_ms: map["updated_at_ms"] || map[:updated_at_ms] || 0,
      expires_at_ms: map["expires_at_ms"] || map[:expires_at_ms],
      metadata: map["metadata"] || map[:metadata] || %{}
    }
  end

  defp generate_id, do: "mem_" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

  defp parse_atom(val, _default) when is_atom(val) and not is_nil(val), do: val

  defp parse_atom(val, default) when is_binary(val) do
    try do
      String.to_existing_atom(val)
    rescue
      _ -> default
    end
  end

  defp parse_atom(_, default), do: default
end
