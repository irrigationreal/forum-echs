defmodule EchsCore.InfraSupervisor do
  @moduledoc false

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {EchsCore.Tools.Exec, name: EchsCore.Tools.Exec},
      {EchsCore.StuckTurnSweeper, []}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
