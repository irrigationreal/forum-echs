defmodule Echs.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      releases: releases()
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:req, "~> 0.5"}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"]
    ]
  end

  defp releases do
    [
      echs_server: [
        applications: [
          echs_server: :permanent,
          echs_core: :permanent,
          echs_codex: :permanent,
          echs_protocol: :permanent,
          runtime_tools: :permanent
        ]
      ]
    ]
  end
end
