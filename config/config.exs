# This file is responsible for configuring your umbrella
# and **all applications** and their dependencies with the
# help of the Config module.
#
# Note that all applications in your umbrella share the
# same configuration and dependencies, which is why they
# all use the same configuration file. If you want different
# configurations or dependencies per app, it is best to
# move said applications out of the umbrella.
import Config

# Sample configuration:
#
#     config :logger, :default_handler,
#       level: :info
#
#     config :logger, :default_formatter,
#       format: "$date $time [$level] $metadata$message\n",
#       metadata: [:user_id]
#

# Avoid binding sockets during `mix test` by default.
config :echs_server,
  start_server: config_env() != :test

# SQLite-backed persistence used by the daemon. In tests we use a single
# in-memory connection for determinism.
config :echs_store,
  ecto_repos: [EchsStore.Repo]

config :echs_store, EchsStore.Repo,
  database:
    (if config_env() == :test do
       ":memory:"
     else
       Path.expand("tmp/echs.db", File.cwd!())
     end),
  pool_size: if(config_env() == :test, do: 1, else: 5),
  journal_mode: :wal,
  synchronous: :normal
