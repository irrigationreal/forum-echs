defmodule EchsServer.Application do
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    children = [
      # Registries must be up before event buffers
      {Registry, keys: :unique, name: EchsServer.ThreadEventRegistry},
      {Registry, keys: :unique, name: EchsServer.ConversationEventRegistry},

      # Metrics (attaches telemetry handlers, must be up before traffic)
      EchsServer.Metrics,

      # Dynamic supervisors for event buffers
      {DynamicSupervisor, strategy: :one_for_one, name: EchsServer.ThreadEventSupervisor},
      {DynamicSupervisor, strategy: :one_for_one, name: EchsServer.ConversationEventSupervisor}
    ]

    children =
      if Application.get_env(:echs_server, :start_server, true) do
        children ++ [{Bandit, bandit_options()}]
      else
        children
      end

    # rest_for_one: if a registry crashes, downstream supervisors restart
    opts = [strategy: :rest_for_one, name: EchsServer.Supervisor]

    if Application.get_env(:echs_server, :start_server, true) do
      Logger.info(
        "ECHS server listening on http://#{EchsServer.default_bind()}:#{EchsServer.default_port()}"
      )
    end

    case Supervisor.start_link(children, opts) do
      {:ok, _pid} = result ->
        _ = EchsServer.AutoResume.start()
        result

      other ->
        other
    end
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
