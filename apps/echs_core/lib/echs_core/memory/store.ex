defmodule EchsCore.Memory.Store do
  @moduledoc """
  In-memory store for memories with persistence support.

  Provides CRUD operations, tag-based and type-based queries,
  privacy-filtered access, and expiry management.
  """

  use GenServer
  require Logger

  alias EchsCore.Memory.Memory

  @type t :: %__MODULE__{
          memories: %{optional(String.t()) => Memory.t()},
          tag_index: %{optional(String.t()) => MapSet.t()},
          type_index: %{optional(atom()) => MapSet.t()},
          conversation_index: %{optional(String.t()) => MapSet.t()}
        }

  defstruct [
    memories: %{},
    tag_index: %{},
    type_index: %{},
    conversation_index: %{}
  ]

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  end

  @doc "Store a memory."
  @spec put(GenServer.server(), Memory.t()) :: :ok
  def put(store, %Memory{} = memory) do
    GenServer.call(store, {:put, memory})
  end

  @doc "Get a memory by ID."
  @spec get(GenServer.server(), String.t()) :: {:ok, Memory.t()} | {:error, :not_found}
  def get(store, memory_id) do
    GenServer.call(store, {:get, memory_id})
  end

  @doc "Delete a memory by ID."
  @spec delete(GenServer.server(), String.t()) :: :ok
  def delete(store, memory_id) do
    GenServer.call(store, {:delete, memory_id})
  end

  @doc "Update a memory."
  @spec update(GenServer.server(), String.t(), keyword()) ::
          {:ok, Memory.t()} | {:error, :not_found}
  def update(store, memory_id, updates) do
    GenServer.call(store, {:update, memory_id, updates})
  end

  @doc "Query memories by tags (AND matching)."
  @spec query_by_tags(GenServer.server(), [String.t()], keyword()) :: [Memory.t()]
  def query_by_tags(store, tags, opts \\ []) do
    GenServer.call(store, {:query_by_tags, tags, opts})
  end

  @doc "Query memories by type."
  @spec query_by_type(GenServer.server(), Memory.memory_type(), keyword()) :: [Memory.t()]
  def query_by_type(store, type, opts \\ []) do
    GenServer.call(store, {:query_by_type, type, opts})
  end

  @doc "Query memories for a conversation."
  @spec query_by_conversation(GenServer.server(), String.t(), keyword()) :: [Memory.t()]
  def query_by_conversation(store, conversation_id, opts \\ []) do
    GenServer.call(store, {:query_by_conversation, conversation_id, opts})
  end

  @doc "Search memories by content substring."
  @spec search(GenServer.server(), String.t(), keyword()) :: [Memory.t()]
  def search(store, query, opts \\ []) do
    GenServer.call(store, {:search, query, opts})
  end

  @doc "List all memories (with optional filters)."
  @spec list(GenServer.server(), keyword()) :: [Memory.t()]
  def list(store, opts \\ []) do
    GenServer.call(store, {:list, opts})
  end

  @doc "Remove expired memories and return count removed."
  @spec sweep_expired(GenServer.server()) :: non_neg_integer()
  def sweep_expired(store) do
    GenServer.call(store, :sweep_expired)
  end

  @doc "Export all memories as a list of maps."
  @spec export(GenServer.server()) :: [map()]
  def export(store) do
    GenServer.call(store, :export)
  end

  @doc "Import memories from a list of maps."
  @spec import_memories(GenServer.server(), [map()]) :: :ok
  def import_memories(store, memories) do
    GenServer.call(store, {:import, memories})
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_opts) do
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call({:put, memory}, _from, state) do
    state = do_put(state, memory)
    {:reply, :ok, state}
  end

  def handle_call({:get, memory_id}, _from, state) do
    case Map.get(state.memories, memory_id) do
      nil -> {:reply, {:error, :not_found}, state}
      mem -> {:reply, {:ok, mem}, state}
    end
  end

  def handle_call({:delete, memory_id}, _from, state) do
    state = do_delete(state, memory_id)
    {:reply, :ok, state}
  end

  def handle_call({:update, memory_id, updates}, _from, state) do
    case Map.get(state.memories, memory_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      mem ->
        # Remove old indices
        state = do_delete(state, memory_id)
        # Apply updates
        updated = apply_updates(mem, updates)
        state = do_put(state, updated)
        {:reply, {:ok, updated}, state}
    end
  end

  def handle_call({:query_by_tags, tags, opts}, _from, state) do
    result =
      tags
      |> Enum.map(fn tag -> Map.get(state.tag_index, tag, MapSet.new()) end)
      |> Enum.reduce(fn set, acc -> MapSet.intersection(set, acc) end)
      |> MapSet.to_list()
      |> Enum.flat_map(fn id ->
        case Map.get(state.memories, id) do
          nil -> []
          mem -> [mem]
        end
      end)
      |> apply_filters(opts)

    {:reply, result, state}
  end

  def handle_call({:query_by_type, type, opts}, _from, state) do
    ids = Map.get(state.type_index, type, MapSet.new())

    result =
      ids
      |> MapSet.to_list()
      |> Enum.flat_map(fn id ->
        case Map.get(state.memories, id) do
          nil -> []
          mem -> [mem]
        end
      end)
      |> apply_filters(opts)

    {:reply, result, state}
  end

  def handle_call({:query_by_conversation, conversation_id, opts}, _from, state) do
    ids = Map.get(state.conversation_index, conversation_id, MapSet.new())

    result =
      ids
      |> MapSet.to_list()
      |> Enum.flat_map(fn id ->
        case Map.get(state.memories, id) do
          nil -> []
          mem -> [mem]
        end
      end)
      |> apply_filters(opts)

    {:reply, result, state}
  end

  def handle_call({:search, query, opts}, _from, state) do
    query_lower = String.downcase(query)

    result =
      state.memories
      |> Map.values()
      |> Enum.filter(fn mem ->
        String.contains?(String.downcase(mem.content), query_lower)
      end)
      |> apply_filters(opts)

    {:reply, result, state}
  end

  def handle_call({:list, opts}, _from, state) do
    result =
      state.memories
      |> Map.values()
      |> apply_filters(opts)

    {:reply, result, state}
  end

  def handle_call(:sweep_expired, _from, state) do
    now = System.system_time(:millisecond)

    expired_ids =
      state.memories
      |> Enum.filter(fn {_id, mem} ->
        mem.expires_at_ms != nil and now > mem.expires_at_ms
      end)
      |> Enum.map(fn {id, _} -> id end)

    state = Enum.reduce(expired_ids, state, &do_delete(&2, &1))
    {:reply, length(expired_ids), state}
  end

  def handle_call(:export, _from, state) do
    result = state.memories |> Map.values() |> Enum.map(&Memory.to_map/1)
    {:reply, result, state}
  end

  def handle_call({:import, memories}, _from, state) do
    state =
      Enum.reduce(memories, state, fn map, acc ->
        mem = Memory.from_map(map)
        do_put(acc, mem)
      end)

    {:reply, :ok, state}
  end

  # --- Internal ---

  defp do_put(state, %Memory{} = mem) do
    memories = Map.put(state.memories, mem.memory_id, mem)

    tag_index =
      Enum.reduce(mem.tags, state.tag_index, fn tag, idx ->
        Map.update(idx, tag, MapSet.new([mem.memory_id]), &MapSet.put(&1, mem.memory_id))
      end)

    type_index =
      Map.update(
        state.type_index,
        mem.memory_type,
        MapSet.new([mem.memory_id]),
        &MapSet.put(&1, mem.memory_id)
      )

    conversation_index =
      if mem.conversation_id do
        Map.update(
          state.conversation_index,
          mem.conversation_id,
          MapSet.new([mem.memory_id]),
          &MapSet.put(&1, mem.memory_id)
        )
      else
        state.conversation_index
      end

    %{
      state
      | memories: memories,
        tag_index: tag_index,
        type_index: type_index,
        conversation_index: conversation_index
    }
  end

  defp do_delete(state, memory_id) do
    case Map.get(state.memories, memory_id) do
      nil ->
        state

      mem ->
        memories = Map.delete(state.memories, memory_id)

        tag_index =
          Enum.reduce(mem.tags, state.tag_index, fn tag, idx ->
            case Map.get(idx, tag) do
              nil ->
                idx

              set ->
                new_set = MapSet.delete(set, memory_id)

                if MapSet.size(new_set) == 0,
                  do: Map.delete(idx, tag),
                  else: Map.put(idx, tag, new_set)
            end
          end)

        type_index =
          case Map.get(state.type_index, mem.memory_type) do
            nil ->
              state.type_index

            set ->
              new_set = MapSet.delete(set, memory_id)

              if MapSet.size(new_set) == 0 do
                Map.delete(state.type_index, mem.memory_type)
              else
                Map.put(state.type_index, mem.memory_type, new_set)
              end
          end

        conversation_index =
          if mem.conversation_id do
            case Map.get(state.conversation_index, mem.conversation_id) do
              nil ->
                state.conversation_index

              set ->
                new_set = MapSet.delete(set, memory_id)

                if MapSet.size(new_set) == 0 do
                  Map.delete(state.conversation_index, mem.conversation_id)
                else
                  Map.put(state.conversation_index, mem.conversation_id, new_set)
                end
            end
          else
            state.conversation_index
          end

        %{
          state
          | memories: memories,
            tag_index: tag_index,
            type_index: type_index,
            conversation_index: conversation_index
        }
    end
  end

  defp apply_updates(mem, updates) do
    now = System.system_time(:millisecond)

    mem
    |> then(fn m ->
      if Keyword.has_key?(updates, :content), do: %{m | content: updates[:content]}, else: m
    end)
    |> then(fn m ->
      if Keyword.has_key?(updates, :tags), do: %{m | tags: updates[:tags]}, else: m
    end)
    |> then(fn m ->
      if Keyword.has_key?(updates, :confidence),
        do: Memory.update_confidence(m, updates[:confidence]),
        else: m
    end)
    |> then(fn m ->
      if Keyword.has_key?(updates, :privacy), do: %{m | privacy: updates[:privacy]}, else: m
    end)
    |> then(fn m ->
      if Keyword.has_key?(updates, :expires_at_ms),
        do: %{m | expires_at_ms: updates[:expires_at_ms]},
        else: m
    end)
    |> then(fn m ->
      if Keyword.has_key?(updates, :metadata), do: %{m | metadata: updates[:metadata]}, else: m
    end)
    |> Map.put(:updated_at_ms, now)
  end

  defp apply_filters(memories, opts) do
    privacy = Keyword.get(opts, :privacy, :internal)
    min_confidence = Keyword.get(opts, :min_confidence, 0.0)
    limit = Keyword.get(opts, :limit)
    exclude_expired = Keyword.get(opts, :exclude_expired, true)

    memories
    |> Enum.filter(fn mem -> Memory.visible?(mem, privacy) end)
    |> Enum.filter(fn mem -> mem.confidence >= min_confidence end)
    |> then(fn mems ->
      if exclude_expired do
        Enum.reject(mems, &Memory.expired?/1)
      else
        mems
      end
    end)
    |> Enum.sort_by(& &1.confidence, :desc)
    |> then(fn mems -> if limit, do: Enum.take(mems, limit), else: mems end)
  end
end
