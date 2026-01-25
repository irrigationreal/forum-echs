import Config

# Runtime config for releases.
#
# ECHS currently reads most daemon settings directly from environment variables
# (see `apps/echs_server/lib/echs_server.ex`), but we keep this file so
# deployments have a conventional place to add runtime-only config.

if config_env() == :prod do
  level =
    case System.get_env("LOG_LEVEL") do
      nil -> :info
      "" -> :info
      "debug" -> :debug
      "info" -> :info
      "notice" -> :notice
      "warning" -> :warning
      "error" -> :error
      "critical" -> :critical
      "alert" -> :alert
      "emergency" -> :emergency
      _ -> :info
    end

  config :logger, level: level

  db_path = System.get_env("ECHS_DB_PATH") || Path.expand("tmp/echs.db", File.cwd!())
  pool_size = System.get_env("ECHS_DB_POOL_SIZE") || "5"

  config :echs_store, EchsStore.Repo,
    database: db_path,
    pool_size: String.to_integer(pool_size),
    journal_mode: :wal,
    synchronous: :normal
end
