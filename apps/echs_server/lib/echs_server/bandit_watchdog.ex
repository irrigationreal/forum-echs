defmodule EchsServer.BanditWatchdog do
  @moduledoc """
  Watchdog process that monitors Bandit HTTP server health.
  If the server stops responding, it forcefully restarts it.
  """
  use GenServer
  require Logger

  @check_interval 10_000  # Check every 10 seconds
  @connect_timeout 2_000  # 2 second timeout for health check

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    schedule_check()
    {:ok, %{consecutive_failures: 0}}
  end

  @impl true
  def handle_info(:check_health, state) do
    state = check_and_maybe_restart(state)
    schedule_check()
    {:noreply, state}
  end

  defp schedule_check do
    Process.send_after(self(), :check_health, @check_interval)
  end

  defp check_and_maybe_restart(state) do
    port = EchsServer.default_port()

    case check_port_open(port) do
      :ok ->
        # Reset failure counter on success
        %{state | consecutive_failures: 0}

      :error ->
        failures = state.consecutive_failures + 1
        Logger.warning("BanditWatchdog: port #{port} not responding (failure #{failures})")

        if failures >= 2 do
          Logger.error("BanditWatchdog: restarting Bandit after #{failures} consecutive failures")
          restart_bandit()
          %{state | consecutive_failures: 0}
        else
          %{state | consecutive_failures: failures}
        end
    end
  end

  defp check_port_open(port) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [], @connect_timeout) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        :ok

      {:error, _reason} ->
        :error
    end
  end

  defp restart_bandit do
    # Find and restart the Bandit supervisor
    case Process.whereis(EchsServer.Supervisor) do
      nil ->
        Logger.error("BanditWatchdog: EchsServer.Supervisor not found!")

      sup_pid ->
        # Find the BanditSupervisor child
        children = Supervisor.which_children(sup_pid)

        case Enum.find(children, fn {id, _, _, _} -> id == EchsServer.BanditSupervisor end) do
          {_, pid, _, _} when is_pid(pid) ->
            Logger.info("BanditWatchdog: terminating BanditSupervisor (#{inspect(pid)})")
            # Terminate and let the supervisor restart it
            Supervisor.terminate_child(sup_pid, EchsServer.BanditSupervisor)
            Supervisor.restart_child(sup_pid, EchsServer.BanditSupervisor)

          _ ->
            Logger.error("BanditWatchdog: BanditSupervisor child not found")
        end
    end
  end
end
