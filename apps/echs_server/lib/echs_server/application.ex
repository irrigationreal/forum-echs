defmodule EchsServer.Application do
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    base_children = [
      {Registry, keys: :unique, name: EchsServer.ThreadEventRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: EchsServer.ThreadEventSupervisor}
    ]

    children =
      if Application.get_env(:echs_server, :start_server, true) do
        base_children ++
          [
            {Bandit, bandit_options()}
          ]
      else
        base_children
      end

    opts = [strategy: :one_for_one, name: EchsServer.Supervisor]

    if children != [] do
      Logger.info(
        "ECHS server listening on http://#{EchsServer.default_bind()}:#{EchsServer.default_port()}"
      )
    end

    Supervisor.start_link(children, opts)
  end

  defp bandit_options do
    [
      plug: EchsServer.Router,
      scheme: :http,
      ip: bind_ip(EchsServer.default_bind()),
      port: EchsServer.default_port()
    ]
  end

  defp bind_ip("0.0.0.0"), do: {0, 0, 0, 0}
  defp bind_ip("::"), do: {0, 0, 0, 0, 0, 0, 0, 0}

  defp bind_ip(other) when is_binary(other) do
    case :inet.parse_address(String.to_charlist(other)) do
      {:ok, ip} -> ip
      {:error, _} -> {0, 0, 0, 0}
    end
  end
end
