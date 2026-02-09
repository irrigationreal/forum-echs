defmodule EchsServer.ConversationEventBuffer do
  @moduledoc """
  Buffers conversation events and forwards thread events across session switches.
  """

  use GenServer

  @buffer_size 500
  @inactivity_timeout_ms 30 * 60 * 1000

  def start_link(conversation_id) do
    GenServer.start_link(__MODULE__, conversation_id, name: via(conversation_id))
  end

  def ensure_started(conversation_id) do
    do_ensure_started(conversation_id)
  end

  def subscribe(conversation_id, last_event_id \\ nil) do
    {:ok, pid} = do_ensure_started(conversation_id)
    :ok = GenServer.call(pid, {:subscribe, self(), last_event_id})
    {:ok, pid}
  end

  def attach_thread(conversation_id, thread_id) do
    {:ok, pid} = do_ensure_started(conversation_id)
    GenServer.cast(pid, {:attach_thread, thread_id})
  end

  def emit(conversation_id, event_type, data) do
    {:ok, pid} = do_ensure_started(conversation_id)
    GenServer.cast(pid, {:emit, event_type, data})
  end

  defp do_ensure_started(conversation_id) do
    case Registry.lookup(EchsServer.ConversationEventRegistry, conversation_id) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        case DynamicSupervisor.start_child(
               EchsServer.ConversationEventSupervisor,
               {__MODULE__, conversation_id}
             ) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          error -> error
        end
    end
  end

  defp via(conversation_id) do
    {:via, Registry, {EchsServer.ConversationEventRegistry, conversation_id}}
  end

  @impl true
  def init(conversation_id) do
    {:ok,
     %{conversation_id: conversation_id, seq: 0, events: [], watchers: %{}, threads: MapSet.new()},
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

    Enum.each(backlog, fn {id, type, data} ->
      send(pid, {:event, id, type, data})
    end)

    {:reply, :ok, state, @inactivity_timeout_ms}
  end

  @impl true
  def handle_cast({:attach_thread, thread_id}, state) do
    state =
      if MapSet.member?(state.threads, thread_id) do
        state
      else
        :ok = EchsCore.subscribe(thread_id)
        %{state | threads: MapSet.put(state.threads, thread_id)}
      end

    {:noreply, state, @inactivity_timeout_ms}
  end

  @impl true
  def handle_cast({:emit, event_type, data}, state) do
    {state, _id} = push_event(state, event_type, data)
    {:noreply, state, @inactivity_timeout_ms}
  end

  @impl true
  def handle_info({event_type, data}, state) when is_atom(event_type) do
    {state, _id} = push_event(state, event_type, data)
    {:noreply, state, @inactivity_timeout_ms}
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
    {:noreply, state, @inactivity_timeout_ms}
  end

  defp push_event(state, event_type, data) do
    id = state.seq + 1
    event = {id, event_type, data}
    events = trim_events(state.events ++ [event])

    Enum.each(state.watchers, fn {pid, _ref} ->
      send(pid, {:event, id, event_type, data})
    end)

    {%{state | seq: id, events: events}, id}
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
