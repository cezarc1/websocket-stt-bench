defmodule SttGateway.MixProject do
  use Mix.Project

  def project do
    [
      app: :stt_gateway,
      version: "0.1.0",
      elixir: "1.19.5",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      releases: releases(),
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit]
      ]
    ]
  end

  def application do
    [
      mod: {SttGateway.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:phoenix, "1.8.5"},
      {:bandit, "1.11.0"},
      {:websock_adapter, "0.5.8"},
      {:finch, "0.21.0"},
      {:credo, "1.7.18", only: [:dev, :test], runtime: false},
      {:dialyxir, "1.4.7", only: [:dev], runtime: false}
    ]
  end

  defp aliases do
    [
      test: ["test"]
    ]
  end

  defp releases do
    [
      stt_gateway: [
        include_executables_for: [:unix],
        applications: [runtime_tools: :permanent]
      ]
    ]
  end
end
