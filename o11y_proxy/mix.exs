defmodule O11yProxy.MixProject do
  use Mix.Project

  def project do
    [
      app: :o11y_proxy,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {O11yProxy.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:bandit, "~> 1.5"},
      {:plug, "~> 1.16"},
      {:jason, "~> 1.4"},
      {:yaml_elixir, "~> 2.11"},
      {:nimble_options, "~> 1.1"},
      {:req, "~> 0.5"},
      {:ch, "~> 0.9"},
      {:telemetry, "~> 1.3"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_metrics_prometheus_core, "~> 1.1"},
      {:telemetry_poller, "~> 1.1"}
    ]
  end
end
