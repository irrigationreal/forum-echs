defmodule EchsCodex.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {EchsCodex.Auth, []}
    ]

    opts = [strategy: :one_for_one, name: EchsCodex.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
