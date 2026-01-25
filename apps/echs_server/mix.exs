defmodule EchsServer.MixProject do
  use Mix.Project

  def project do
    [
      app: :echs_server,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {EchsServer.Application, []}
    ]
  end

  defp deps do
    [
      {:echs_core, in_umbrella: true},
      {:echs_codex, in_umbrella: true},
      {:echs_protocol, in_umbrella: true},
      {:jason, "~> 1.4"},
      {:plug, "~> 1.15"},
      {:bandit, "~> 1.5"}
    ]
  end
end
