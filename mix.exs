defmodule O11yProxy.MixProject do
  use Mix.Project

  def project do
    [
      app: :o11y_proxy,
      version: "0.2.1",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),
      releases: releases(),
      # `:ex_unit` because elixirc_paths/1 compiles test/support in the test env, and CI
      # runs dialyzer there — O11yProxy.BackendCase calls ExUnit.Assertions, which is not
      # otherwise in the PLT. Without it dialyzer is green locally in :dev and red in CI.
      dialyzer: [
        plt_local_path: "priv/plts",
        plt_core_path: "priv/plts",
        plt_add_apps: [:ex_unit]
      ]
    ]
  end

  # `precommit` and `ci` are test-env so they compile and lint the test tree too — a
  # warning or a Credo finding in test/ should fail the same gate that catches one in lib/.
  def cli do
    [preferred_envs: [precommit: :test, ci: :test]]
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
      {:burrito, "~> 1.6", runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_dna, "~> 1.5", only: [:dev, :test], runtime: false},
      {:reach, "~> 2.7", only: [:dev, :test], runtime: false}
    ]
  end

  # Two gates, deliberately different:
  #
  #   * `precommit` is local and *mutating* — it formats and prunes rather than complaining
  #     that you should have. Run it before pushing.
  #   * `ci` is a non-mutating superset: the same checks in --check mode, plus the audits
  #     and the architecture/smell policy. It must never write to the working tree, so a
  #     CI failure is always about the code and never about CI having edited it.
  defp aliases do
    [
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "credo --strict",
        "ex_dna",
        "test"
      ],
      ci: [
        "hex.audit",
        "compile --warnings-as-errors",
        "deps.unlock --check-unused",
        "format --check-formatted",
        "credo --strict",
        "deps.audit",
        "ex_dna",
        "reach.check --arch --smells --strict --baseline .reach.baseline.json"
      ]
    ]
  end
end
