defmodule EchsCodex.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    # In umbrella test runs, echs_codex's test_helper.exs may have started
    # CircuitBreaker (and/or Auth) as standalone processes outside any
    # supervision tree.  When a later app (echs_core, echs_server) calls
    # Application.ensure_all_started(:echs_codex), the supervisor would fail
    # with {:already_started, pid}.  Stop any orphaned instances so the
    # supervisor can start fresh supervised copies.
    stop_if_running(EchsCodex.CircuitBreaker)
    stop_if_running(EchsCodex.Auth)

    children = [
      {EchsCodex.Auth, []},
      EchsCodex.CircuitBreaker
    ]

    opts = [strategy: :one_for_one, name: EchsCodex.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp stop_if_running(name) do
    case GenServer.whereis(name) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal, 5_000)
    end
  catch
    :exit, _ -> :ok
  end
end
