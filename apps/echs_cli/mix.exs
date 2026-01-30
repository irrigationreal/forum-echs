defmodule EchsCli.MixProject do
  use Mix.Project

  def project do
    [
      app: :echs_cli,
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

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:echs_core, in_umbrella: true},
      {:echs_codex, in_umbrella: true},
      {:ratatouille, "~> 0.5.1"}
    ]
  end
end
