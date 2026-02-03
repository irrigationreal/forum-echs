defmodule EchsServer.ThreadEventBuffer do
  @moduledoc """
  Buffers recent thread events and assigns monotonically increasing IDs.

  This enables SSE clients to resume with Last-Event-ID.
  """

  use GenServer

  @buffer_size 500
  # Terminate after 30 minutes of inactivity to avoid accumulating buffers
  # for terminated threads.
  @inactivity_timeout_ms 30 * 60 * 1000

  def start_link(thread_id) do
    GenServer.start_link(__MODULE__, thread_id, name: via(thread_id))
  end

  def ensure_started(thread_id) do
    do_ensure_started(thread_id)
  end

  def subscribe(thread_id, last_event_id \\ nil) do
    {:ok, pid} = do_ensure_started(thread_id)
    GenServer.call(pid, {:subscribe, self(), last_event_id})
  end

  defp do_ensure_started(thread_id) do
    case Registry.lookup(EchsServer.ThreadEventRegistry, thread_id) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        case DynamicSupervisor.start_child(
               EchsServer.ThreadEventSupervisor,
               {__MODULE__, thread_id}
             ) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          error -> error
        end
    end
  end

  defp via(thread_id) do
    {:via, Registry, {EchsServer.ThreadEventRegistry, thread_id}}
  end

  @impl true
  def init(thread_id) do
    :ok = EchsCore.subscribe(thread_id)
    {:ok, %{thread_id: thread_id, seq: 0, oldest_id: 0, events: [], watchers: %{}},
     @inactivity_timeout_ms}
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

    # If the client requested events that have been trimmed from the buffer,
    # send a gap indicator so it knows data was lost.
    if last_id != nil and last_id < state.oldest_id do
      send(pid, {:event, 0, :events_gap, %{
        oldest_available: state.oldest_id,
        requested_after: last_id
      }})
    end

    Enum.each(backlog, fn {id, type, data} ->
      send(pid, {:event, id, type, data})
    end)

    {:reply, :ok, state, @inactivity_timeout_ms}
  end

  @impl true
  def handle_info({event_type, data}, state)
      when is_atom(event_type) do
    id = state.seq + 1
    event = {id, event_type, data}
    {events, oldest_id} = trim_events(state.events ++ [event], state.oldest_id)

    Enum.each(state.watchers, fn {pid, _ref} ->
      send(pid, {:event, id, event_type, data})
    end)

    {:noreply, %{state | seq: id, events: events, oldest_id: oldest_id},
     @inactivity_timeout_ms}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    watchers =
      case Map.get(state.watchers, pid) do
        ^ref -> Map.delete(state.watchers, pid)
        _ -> state.watchers
      end

    {:noreply, %{state | watchers: watchers}, @inactivity_timeout_ms}
  end

  @impl true
  def handle_info(:timeout, state) do
    {:stop, :normal, state}
  end

  @impl true
  def handle_info(_msg, state) do
    # Ignore unexpected messages (non-atom-keyed tuples, system messages, etc.)
    {:noreply, state, @inactivity_timeout_ms}
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

  defp trim_events(events, oldest_id) do
    excess = length(events) - @buffer_size

    if excess > 0 do
      trimmed = Enum.drop(events, excess)

      new_oldest =
        case trimmed do
          [{id, _, _} | _] -> id
          [] -> oldest_id
        end

      {trimmed, new_oldest}
    else
      {events, oldest_id}
    end
  end
end
