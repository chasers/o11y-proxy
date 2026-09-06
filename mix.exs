defmodule O11yProxy.MixProject do
  use Mix.Project

  def project do
    [
      app: :o11y_proxy,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      releases: releases()
    ]
  end

  # Single-file executables via Burrito — `.plans/05-roadmap.md` Phase 6's "installable".
  # Needs Zig 0.16.0 (pinned in .tool-versions) and xz on the build host; Windows targets
  # would also need 7z, and aren't built since this is a loopback daemon.
  #
  #     MIX_ENV=prod mix release                      # every target below
  #     BURRITO_TARGET=linux_aarch64 MIX_ENV=prod mix release   # just one
  #
  # Output lands in burrito_out/.
  defp releases do
    [
      o11y_proxy: [
        # `:tar` also emits a plain OTP release tarball for the *build host's* platform
        # alongside the cross-compiled single-file binaries. The binary is the nice
        # download-and-run path; the tarball is what you want under systemd, since it
        # keeps the standard `bin/o11y_proxy start|daemon|stop|remote` script (Burrito
        # binaries have no daemon/stop/remote — they're a CLI launcher, see
        # keep_alive_if_release/0 in application.ex).
        steps: [:assemble, :tar, &Burrito.wrap/1],
        burrito: [
          targets: [
            linux_aarch64: [os: :linux, cpu: :aarch64],
            linux_x86_64: [os: :linux, cpu: :x86_64],
            macos_silicon: [os: :darwin, cpu: :aarch64],
            macos_x86_64: [os: :darwin, cpu: :x86_64]
          ]
        ]
      ]
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
      {:telemetry_poller, "~> 1.1"},
      {:burrito, "~> 1.6", runtime: false}
    ]
  end
end
