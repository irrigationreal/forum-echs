defmodule EchsCore.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Registry for thread_id -> pid lookup
      {Registry, keys: :unique, name: EchsCore.Registry},

      # DynamicSupervisor for ThreadWorker processes
      {DynamicSupervisor, strategy: :one_for_one, name: EchsCore.ThreadSupervisor},

      # Task supervisor for tool execution
      {Task.Supervisor, name: EchsCore.TaskSupervisor},

      # Global blackboard
      {EchsCore.Blackboard, name: EchsCore.Blackboard.Global},

      # Exec session manager (UnifiedExec-style sessions; port-backed stdio)
      {EchsCore.Tools.Exec, name: EchsCore.Tools.Exec},

      # Global concurrency limiter for turns
      {EchsCore.TurnLimiter, name: EchsCore.TurnLimiter},

      # PubSub for events
      {Phoenix.PubSub, name: EchsCore.PubSub}
    ]

    opts = [strategy: :one_for_one, name: EchsCore.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
