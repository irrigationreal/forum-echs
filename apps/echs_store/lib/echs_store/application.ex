defmodule EchsStore.Application do
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    children = [
      EchsStore.Repo,
      EchsStore.WriteBuffer
    ]

    opts = [strategy: :one_for_one, name: EchsStore.Supervisor]
    {:ok, sup} = Supervisor.start_link(children, opts)

    if auto_migrate?() do
      case EchsStore.Migrator.migrate() do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.error("ECHS store migration failed: #{inspect(reason)}")
      end
    end

    {:ok, sup}
  end

  defp auto_migrate? do
    case Application.get_env(:echs_store, :auto_migrate, nil) do
      true ->
        true

      false ->
        false

      nil ->
        case System.get_env("ECHS_AUTO_MIGRATE") do
          nil -> true
          "" -> true
          "0" -> false
          "false" -> false
          "no" -> false
          _ -> true
        end
    end
  end
end
