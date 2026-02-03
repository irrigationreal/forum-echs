defmodule EchsCore.TurnLimiter do
  @moduledoc """
  Global concurrency limiter for turn execution.

  Keeps a global cap on active turns across all threads and queues waiters.
  By default, concurrency is unlimited; set a cap via `ECHS_MAX_CONCURRENT_TURNS`
  (or `:echs_core, :max_concurrent_turns`) if needed for resource control.

  Monitors holder processes: if a holder crashes, the slot is automatically
  released so it doesn't leak permanently.
  """

  use GenServer

  require Logger

  @name __MODULE__
  @default_limit :infinity

  @type slot_ref :: reference()

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @spec acquire() :: {:ok, slot_ref()} | {:wait, slot_ref()}
  def acquire do
    GenServer.call(@name, {:acquire, self()})
  end

  @spec release(slot_ref()) :: :ok
  def release(ref) when is_reference(ref) do
    GenServer.cast(@name, {:release, ref})
  end

  @spec cancel(slot_ref()) :: :ok
  def cancel(ref) when is_reference(ref) do
    GenServer.cast(@name, {:cancel, ref})
  end

  @impl true
  def init(opts) do
    limit =
      opts
      |> Keyword.get(:limit, default_limit())
      |> normalize_limit()

    {:ok,
     %{
       limit: limit,
       in_use: MapSet.new(),
       queue: :queue.new(),
       # ref -> {pid, monitor_ref} — tracks monitored holders
       monitors: %{}
     }}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      limit: state.limit,
      in_use: MapSet.size(state.in_use),
      queue_size: :queue.len(state.queue)
    }

    {:reply, status, state}
  end

  def handle_call({:acquire, _pid}, _from, %{limit: :infinity} = state) do
    ref = make_ref()
    {:reply, {:ok, ref}, state}
  end

  def handle_call({:acquire, pid}, _from, state) do
    ref = make_ref()

    cond do
      MapSet.size(state.in_use) < state.limit ->
        mon = Process.monitor(pid)

        state = %{
          state
          | in_use: MapSet.put(state.in_use, ref),
            monitors: Map.put(state.monitors, ref, {pid, mon})
        }

        EchsCore.Telemetry.limiter_acquire(:ok, :queue.len(state.queue))
        {:reply, {:ok, ref}, state}

      true ->
        queue = :queue.in({ref, pid}, state.queue)
        EchsCore.Telemetry.limiter_acquire(:wait, :queue.len(queue))
        {:reply, {:wait, ref}, %{state | queue: queue}}
    end
  end

  @impl true
  def handle_cast({:release, _ref}, %{limit: :infinity} = state) do
    {:noreply, state}
  end

  def handle_cast({:release, ref}, state) do
    state = release_slot(state, ref)
    {:noreply, grant_next(state)}
  end

  @impl true
  def handle_cast({:cancel, _ref}, %{limit: :infinity} = state) do
    {:noreply, state}
  end

  def handle_cast({:cancel, ref}, state) do
    {:noreply, %{state | queue: drop_ref(state.queue, ref)}}
  end

  # When a monitored holder process crashes, release its slot automatically
  @impl true
  def handle_info({:DOWN, _mon_ref, :process, _pid, _reason}, %{limit: :infinity} = state) do
    {:noreply, state}
  end

  def handle_info({:DOWN, mon_ref, :process, pid, reason}, state) do
    case find_ref_by_monitor(state.monitors, mon_ref) do
      {:ok, slot_ref} ->
        Logger.warning(
          "turn_limiter releasing slot for crashed process pid=#{inspect(pid)} reason=#{inspect(reason)}"
        )

        state = release_slot(state, slot_ref)
        {:noreply, grant_next(state)}

      :not_found ->
        # May be a queued waiter that died — clean from queue
        queue = drop_pid(state.queue, pid)
        {:noreply, %{state | queue: queue}}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp release_slot(state, ref) do
    case Map.pop(state.monitors, ref) do
      {{_pid, mon}, monitors} ->
        Process.demonitor(mon, [:flush])

        %{
          state
          | in_use: MapSet.delete(state.in_use, ref),
            monitors: monitors
        }

      {nil, _monitors} ->
        %{state | in_use: MapSet.delete(state.in_use, ref)}
    end
  end

  defp grant_next(state) do
    case :queue.out(state.queue) do
      {{:value, {ref, pid}}, queue} ->
        if Process.alive?(pid) do
          mon = Process.monitor(pid)
          send(pid, {:turn_slot_granted, ref})

          %{
            state
            | in_use: MapSet.put(state.in_use, ref),
              queue: queue,
              monitors: Map.put(state.monitors, ref, {pid, mon})
          }
        else
          grant_next(%{state | queue: queue})
        end

      {:empty, _queue} ->
        state
    end
  end

  defp find_ref_by_monitor(monitors, mon_ref) do
    Enum.find_value(monitors, :not_found, fn {slot_ref, {_pid, m}} ->
      if m == mon_ref, do: {:ok, slot_ref}
    end)
  end

  defp drop_ref(queue, ref) do
    queue
    |> :queue.to_list()
    |> Enum.reject(fn {queued_ref, _pid} -> queued_ref == ref end)
    |> :queue.from_list()
  end

  defp drop_pid(queue, pid) do
    queue
    |> :queue.to_list()
    |> Enum.reject(fn {_ref, queued_pid} -> queued_pid == pid end)
    |> :queue.from_list()
  end

  defp normalize_limit(limit) when is_integer(limit) and limit > 0, do: limit
  defp normalize_limit(_), do: :infinity

  defp default_limit do
    case System.get_env("ECHS_MAX_CONCURRENT_TURNS") do
      nil ->
        Application.get_env(:echs_core, :max_concurrent_turns, @default_limit)

      raw ->
        raw = raw |> to_string() |> String.trim() |> String.downcase()

        case raw do
          "infinity" ->
            :infinity

          "unlimited" ->
            :infinity

          "none" ->
            :infinity

          _ ->
            case Integer.parse(raw) do
              {value, _} when value > 0 -> value
              _ -> Application.get_env(:echs_core, :max_concurrent_turns, @default_limit)
            end
        end
    end
  end
end
