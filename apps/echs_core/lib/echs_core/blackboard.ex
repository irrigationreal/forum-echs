defmodule EchsCore.Blackboard do
  @moduledoc """
  Shared state blackboard for sub-agent coordination.
  Uses ETS for fast concurrent reads.
  """

  use GenServer

  @type key :: term()
  @type value :: term()
  @type watcher_set :: MapSet.t(pid())

  defstruct [:table, :watchers, :monitors]

  @type state :: %__MODULE__{
          table: :ets.tid(),
          watchers: %{optional(key()) => watcher_set()},
          monitors: %{optional(pid()) => reference()}
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    case Keyword.get(opts, :name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @impl true
  def init(_opts) do
    table =
      :ets.new(:blackboard, [:set, :public, read_concurrency: true, write_concurrency: true])

    # Store table tid so clients can bypass GenServer for reads/writes
    :persistent_term.put({__MODULE__, self()}, table)

    {:ok, %__MODULE__{table: table, watchers: %{}, monitors: %{}}}
  end

  @impl true
  def terminate(_reason, state) do
    :persistent_term.erase({__MODULE__, self()})
    state
  end

  @doc """
  Set a key-value pair.
  If notify_parent: true, will broadcast to parent thread.
  """
  @spec set(GenServer.server(), key(), value(), keyword()) :: :ok
  def set(blackboard, key, value, opts \\ []) do
    if Keyword.get(opts, :notify_parent, false) do
      # Must go through GenServer for PubSub broadcast + watcher notification
      GenServer.call(blackboard, {:set, key, value, opts})
    else
      # Fast path: write directly to ETS, notify watchers via GenServer cast
      table = resolve_table(blackboard)
      :ets.insert(table, {key, value})
      GenServer.cast(blackboard, {:notify_watchers, key, value})
      :ok
    end
  end

  @doc """
  Get a value by key.
  """
  @spec get(GenServer.server(), key()) :: {:ok, value()} | :not_found
  def get(blackboard, key) do
    table = resolve_table(blackboard)

    case :ets.lookup(table, key) do
      [{^key, value}] -> {:ok, value}
      [] -> :not_found
    end
  end

  @doc """
  Watch a key for changes.
  """
  @spec watch(GenServer.server(), key(), pid()) :: :ok
  def watch(blackboard, key, pid) when is_pid(pid) do
    GenServer.call(blackboard, {:watch, key, pid})
  end

  @doc """
  Clear all keys.
  """
  @spec clear(GenServer.server()) :: :ok
  def clear(blackboard) do
    GenServer.call(blackboard, :clear)
  end

  @doc """
  Get all key-value pairs.
  """
  @spec all(GenServer.server()) :: map()
  def all(blackboard) do
    table = resolve_table(blackboard)
    table |> :ets.tab2list() |> Map.new()
  end

  # Callbacks

  @impl true
  def handle_call({:set, key, value, opts}, _from, state) do
    :ets.insert(state.table, {key, value})

    # Notify watchers
    watchers = Map.get(state.watchers, key, MapSet.new())

    Enum.each(watchers, fn pid ->
      send(pid, {:blackboard_update, key, value})
    end)

    # If notify_parent, broadcast event on per-parent topic
    if Keyword.get(opts, :notify_parent, false) do
      steer_message = Keyword.get(opts, :steer_message)
      by = Keyword.get(opts, :by)
      parent_id = Keyword.get(opts, :parent_thread_id)

      topic =
        if is_binary(parent_id) and parent_id != "" do
          "blackboard:#{parent_id}"
        else
          "blackboard"
        end

      Phoenix.PubSub.broadcast(
        EchsCore.PubSub,
        topic,
        {:blackboard_set, key, value, by, steer_message}
      )
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:watch, key, pid}, _from, state) do
    state = monitor_watcher(state, pid)
    watchers = Map.update(state.watchers, key, MapSet.new([pid]), &MapSet.put(&1, pid))
    {:reply, :ok, %{state | watchers: watchers}}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(state.table)

    Enum.each(state.monitors, fn {_pid, ref} ->
      Process.demonitor(ref, [:flush])
    end)

    {:reply, :ok, %{state | watchers: %{}, monitors: %{}}}
  end

  @impl true
  def handle_cast({:notify_watchers, key, value}, state) do
    watchers = Map.get(state.watchers, key, MapSet.new())

    Enum.each(watchers, fn pid ->
      send(pid, {:blackboard_update, key, value})
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    state =
      if Map.get(state.monitors, pid) == ref do
        watchers = drop_watcher(state.watchers, pid)
        %{state | monitors: Map.delete(state.monitors, pid), watchers: watchers}
      else
        state
      end

    {:noreply, state}
  end

  defp monitor_watcher(state, pid) do
    if Map.has_key?(state.monitors, pid) do
      state
    else
      ref = Process.monitor(pid)
      %{state | monitors: Map.put(state.monitors, pid, ref)}
    end
  end

  # Resolve a GenServer name/pid to the underlying ETS table tid.
  # Uses persistent_term for O(1) lookup without messaging the GenServer.
  defp resolve_table(pid) when is_pid(pid) do
    :persistent_term.get({__MODULE__, pid})
  end

  defp resolve_table(name) do
    resolve_table(GenServer.whereis(name))
  end

  defp drop_watcher(watchers, pid) do
    watchers
    |> Enum.reduce(%{}, fn {key, watcher_set}, acc ->
      updated = MapSet.delete(watcher_set, pid)

      if MapSet.size(updated) == 0 do
        acc
      else
        Map.put(acc, key, updated)
      end
    end)
  end
end
