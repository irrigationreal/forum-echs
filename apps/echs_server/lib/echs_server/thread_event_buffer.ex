defmodule EchsServer.ThreadEventBuffer do
  @moduledoc """
  Buffers recent thread events and assigns monotonically increasing IDs.

  This enables SSE clients to resume with Last-Event-ID.
  """

  use GenServer

  @buffer_size 500

  def start_link(thread_id) do
    GenServer.start_link(__MODULE__, thread_id, name: via(thread_id))
  end

  def subscribe(thread_id, last_event_id \\ nil) do
    {:ok, pid} = ensure_started(thread_id)
    GenServer.call(pid, {:subscribe, self(), last_event_id})
  end

  defp ensure_started(thread_id) do
    case Registry.lookup(EchsServer.ThreadEventRegistry, thread_id) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        DynamicSupervisor.start_child(EchsServer.ThreadEventSupervisor, {__MODULE__, thread_id})
    end
  end

  defp via(thread_id) do
    {:via, Registry, {EchsServer.ThreadEventRegistry, thread_id}}
  end

  @impl true
  def init(thread_id) do
    :ok = EchsCore.subscribe(thread_id)
    {:ok, %{thread_id: thread_id, seq: 0, events: [], watchers: %{}}}
  end

  @impl true
  def handle_call({:subscribe, pid, last_id}, _from, state) do
    ref = Process.monitor(pid)
    watchers = Map.put(state.watchers, pid, ref)
    state = %{state | watchers: watchers}

    last_id = normalize_last_id(last_id)

    backlog =
      case last_id do
        nil -> []
        _ -> Enum.filter(state.events, fn {id, _type, _data} -> id > last_id end)
      end

    Enum.each(backlog, fn {id, type, data} ->
      send(pid, {:event, id, type, data})
    end)

    {:reply, :ok, state}
  end

  @impl true
  def handle_info({event_type, data}, state) do
    id = state.seq + 1
    event = {id, event_type, data}
    events = trim_events(state.events ++ [event])

    Enum.each(state.watchers, fn {pid, _ref} ->
      send(pid, {:event, id, event_type, data})
    end)

    {:noreply, %{state | seq: id, events: events}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    watchers =
      case Map.get(state.watchers, pid) do
        ^ref -> Map.delete(state.watchers, pid)
        _ -> state.watchers
      end

    {:noreply, %{state | watchers: watchers}}
  end

  defp normalize_last_id(nil), do: nil
  defp normalize_last_id(""), do: nil

  defp normalize_last_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> nil
    end
  end

  defp normalize_last_id(value) when is_integer(value), do: value
  defp normalize_last_id(_), do: nil

  defp trim_events(events) do
    excess = length(events) - @buffer_size

    if excess > 0 do
      Enum.drop(events, excess)
    else
      events
    end
  end
end
