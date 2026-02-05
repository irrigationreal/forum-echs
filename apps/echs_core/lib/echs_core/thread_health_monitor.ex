defmodule EchsCore.ThreadHealthMonitor do
  @moduledoc """
  Periodically checks that conversations with an active_thread_id have a
  live ThreadWorker process.  If the thread is dead, attempts to restore it
  from the store.  If restoration fails, clears the active_thread_id so the
  next message creates a fresh thread instead of repeatedly failing.
  """

  use GenServer
  require Logger

  @default_interval_ms 30_000
  @default_batch_limit 100
  # Only revive threads that had activity in the past 24 hours.
  @default_max_age_ms 24 * 60 * 60 * 1_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    interval_ms = opts[:interval_ms] || env_int("ECHS_HEALTH_MONITOR_MS", @default_interval_ms)
    batch_limit = opts[:batch_limit] || env_int("ECHS_HEALTH_MONITOR_LIMIT", @default_batch_limit)

    state = %{
      interval_ms: interval_ms,
      batch_limit: batch_limit
    }

    schedule_check(interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:check, state) do
    if store_available?() do
      check_conversations(state)
    end

    schedule_check(state.interval_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp check_conversations(state) do
    conversations = EchsStore.list_conversations(limit: state.batch_limit)
    now_ms = System.system_time(:millisecond)
    cutoff_ms = now_ms - @default_max_age_ms

    {restored, cleared} =
      Enum.reduce(conversations, {0, 0}, fn conv, {rest_acc, clear_acc} ->
        thread_id = conv.active_thread_id
        activity_ms = conv.last_activity_at_ms || 0

        cond do
          # Skip conversations without an active thread
          not is_binary(thread_id) or thread_id == "" ->
            {rest_acc, clear_acc}

          # Thread is already alive — nothing to do
          thread_alive?(thread_id) ->
            {rest_acc, clear_acc}

          # Too old — just clear the stale reference, don't revive
          activity_ms < cutoff_ms ->
            Logger.info(
              "thread_health_monitor: clearing stale thread (>24h) thread_id=#{thread_id} conversation=#{conv.conversation_id}"
            )

            _ = EchsStore.update_conversation_active_thread(conv.conversation_id, nil)
            {rest_acc, clear_acc + 1}

          # Recent and dead — attempt restoration
          true ->
            case EchsCore.StoreRestore.restore_thread(thread_id) do
              {:ok, _} ->
                Logger.info(
                  "thread_health_monitor: restored dead thread thread_id=#{thread_id} conversation=#{conv.conversation_id}"
                )

                {rest_acc + 1, clear_acc}

              {:error, reason} ->
                Logger.warning(
                  "thread_health_monitor: clearing dead thread thread_id=#{thread_id} conversation=#{conv.conversation_id} reason=#{inspect(reason)}"
                )

                _ = EchsStore.update_conversation_active_thread(conv.conversation_id, nil)
                {rest_acc, clear_acc + 1}
            end
        end
      end)

    if restored > 0 or cleared > 0 do
      Logger.info(
        "thread_health_monitor: restored=#{restored} cleared=#{cleared}"
      )
    end
  end

  defp thread_alive?(thread_id) do
    case Registry.lookup(EchsCore.Registry, thread_id) do
      [{pid, _}] when is_pid(pid) -> Process.alive?(pid)
      _ -> false
    end
  end

  defp store_available? do
    Code.ensure_loaded?(EchsStore) and EchsStore.enabled?()
  end

  defp schedule_check(ms) when is_integer(ms) and ms > 0 do
    Process.send_after(self(), :check, ms)
  end

  defp env_int(name, default) do
    case System.get_env(name) do
      nil ->
        default

      value ->
        case Integer.parse(to_string(value)) do
          {int, _} when int > 0 -> int
          _ -> default
        end
    end
  end
end
