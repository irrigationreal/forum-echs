defmodule EchsCore.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Initialize the ETS table for provider rate limiting before supervision tree starts
    EchsCore.ProviderAdapter.Resilience.init_rate_table()

    children = [
      # Registry must be up before anything that looks up thread pids
      {Registry, keys: :unique, name: EchsCore.Registry},

      # PubSub for events (needed by threads + infra)
      {Phoenix.PubSub, name: EchsCore.PubSub},

      # Global blackboard (ETS-backed shared state for sub-agent coordination)
      {EchsCore.Blackboard, name: EchsCore.Blackboard.Global},

      # Global concurrency limiter for turns
      {EchsCore.TurnLimiter, name: EchsCore.TurnLimiter},

      # Infrastructure supervisor: tools + background sweeper (one_for_one)
      {EchsCore.InfraSupervisor, []},

      # DynamicSupervisor for ThreadWorker processes
      {DynamicSupervisor, strategy: :one_for_one, name: EchsCore.ThreadSupervisor},

      # Task supervisor for streaming and tool execution
      {Task.Supervisor, name: EchsCore.TaskSupervisor}
    ]

    # rest_for_one: if Registry (or PubSub, Blackboard, TurnLimiter) crashes,
    # everything downstream restarts in order — prevents orphaned threads
    opts = [strategy: :rest_for_one, name: EchsCore.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
