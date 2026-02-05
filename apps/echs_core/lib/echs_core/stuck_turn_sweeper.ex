defmodule EchsCore.StuckTurnSweeper do
  @moduledoc false

  use GenServer
  require Logger

  alias EchsCore.HistorySanitizer
  alias EchsStore.Messages

  @default_sweep_ms 60_000
  @default_max_age_ms 300_000
  @default_batch_limit 50

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    state = %{
      sweep_ms: clamp_ms(opts[:sweep_ms] || env_ms("ECHS_STUCK_SWEEP_MS", @default_sweep_ms)),
      max_age_ms: clamp_ms(opts[:max_age_ms] || env_ms("ECHS_STUCK_TURN_MS", @default_max_age_ms)),
      batch_limit:
        opts[:batch_limit] || env_int("ECHS_STUCK_SWEEP_LIMIT", @default_batch_limit)
    }

    schedule_tick(state.sweep_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    if EchsStore.enabled?() do
      sweep(state)
    end

    schedule_tick(state.sweep_ms)
    {:noreply, state}
  end

  defp sweep(state) do
    now_ms = System.system_time(:millisecond)
    cutoff_ms = now_ms - state.max_age_ms

    messages =
      Messages.list_running_messages(before_ms: cutoff_ms, limit: state.batch_limit)

    {repaired, marked} =
      Enum.reduce(messages, {0, 0}, fn msg, {rep_acc, mark_acc} ->
        {rep_added, mark_added} = repair_message(msg, now_ms)
        {rep_acc + rep_added, mark_acc + mark_added}
      end)

    if repaired > 0 or marked > 0 do
      Logger.warning(
        "stuck_turn_sweeper repaired=#{repaired} marked_error=#{marked} cutoff_ms=#{cutoff_ms}"
      )
    end
  end

  defp repair_message(msg, now_ms) do
    thread_id = msg.thread_id
    message_id = msg.message_id

    case Registry.lookup(EchsCore.Registry, thread_id) do
      [{pid, _}] when is_pid(pid) ->
        # Thread is alive — check if it's a zombie (stuck in :running with no
        # recent activity). If so, interrupt it to break the deadlock.
        maybe_interrupt_zombie(thread_id, message_id, now_ms)

      _ ->
        repair_orphaned_message(thread_id, message_id, now_ms)
    end
  end

  defp maybe_interrupt_zombie(thread_id, message_id, now_ms) do
    try do
      state = EchsCore.ThreadWorker.get_state(thread_id)
      last_activity = Map.get(state, :last_activity_at_ms, 0) || 0
      age_ms = now_ms - last_activity

      if state.status == :running and age_ms > @default_max_age_ms do
        Logger.warning(
          "stuck_turn_sweeper: interrupting zombie thread thread_id=#{thread_id} message_id=#{message_id} idle_ms=#{age_ms}"
        )

        _ = EchsCore.ThreadWorker.interrupt(thread_id)
        {0, 0}
      else
        {0, 0}
      end
    catch
      :exit, _ ->
        # Thread died between Registry lookup and get_state — treat as orphaned
        repair_orphaned_message(thread_id, message_id, now_ms)
    end
  end

  defp repair_orphaned_message(thread_id, message_id, now_ms) do
    repair_added =
      case EchsStore.load_all(thread_id) do
        {:ok, items} ->
          repair_items = HistorySanitizer.repair_output_items(items, now_ms)

          if repair_items == [] do
            0
          else
            _ = EchsStore.append_items(thread_id, message_id, repair_items)
            length(repair_items)
          end

        _ ->
          0
      end

    error =
      if repair_added > 0 do
        "stuck turn auto-repaired missing tool outputs"
      else
        "stuck turn timed out; marking message error"
      end

    marked =
      case Messages.mark_message_error(thread_id, message_id, error, now_ms) do
        {:ok, _} -> 1
        _ -> 0
      end

    {repair_added, marked}
  end

  defp schedule_tick(ms) when is_integer(ms) and ms > 0 do
    Process.send_after(self(), :tick, ms)
  end

  defp env_ms(name, default) do
    case System.get_env(name) do
      nil -> default
      value -> parse_int(value, default)
    end
  end

  defp env_int(name, default) do
    case System.get_env(name) do
      nil -> default
      value -> parse_int(value, default)
    end
  end

  defp parse_int(value, default) do
    case Integer.parse(to_string(value)) do
      {int, _} when int > 0 -> int
      _ -> default
    end
  end

  defp clamp_ms(ms) when is_integer(ms) and ms > 0, do: ms
  defp clamp_ms(_), do: @default_sweep_ms
end
