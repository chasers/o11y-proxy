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
      #
      # `:burrito` because it is a `runtime: false` dependency, so it stays out of the PLT
      # by default, and `O11yProxy.Burrito.DuckDBNatives` implements one of its behaviours.
      # `:mix` for `Mix.Tasks.Duckdb.Stage`, which is build-time code living under lib/.
      dialyzer: [
        plt_local_path: "priv/plts",
        plt_core_path: "priv/plts",
        plt_add_apps: [:ex_unit, :burrito, :mix]
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
        steps: release_steps(),
        burrito: [
          # `skip_nifs: true` on every target because Burrito's own NIF cross-build does
          # not fit adbc: it runs `make all`, which stops at the driver manager and never
          # produces `adbc_nif.so`, and it neither passes `FINE_INCLUDE_DIR` nor copies the
          # result back into the payload. `mix duckdb.stage` does that job properly, and
          # `O11yProxy.Burrito.DuckDBNatives` installs what it staged. adbc is this
          # project's only `:elixir_make` dependency, so nothing else is affected.
          #
          # The step also decides what a target gets: musl DuckDB where it is staged, and
          # nothing at all otherwise — ~25MB of libraries that cannot load is worse than
          # an honest error. macOS is the "otherwise": those need a darwin-native build.
          extra_steps: [patch: [post: [O11yProxy.Burrito.DuckDBNatives]]],
          targets: [
            linux_aarch64: [os: :linux, cpu: :aarch64, skip_nifs: true],
            linux_x86_64: [os: :linux, cpu: :x86_64, skip_nifs: true],
            macos_silicon: [os: :darwin, cpu: :aarch64, skip_nifs: true],
            macos_x86_64: [os: :darwin, cpu: :x86_64, skip_nifs: true]
          ]
        ]
      ]
    ]
  end

  # Burrito cross-compiles the four single-file binaries and needs Zig on the host; the
  # OTP tarball needs neither, and the jobs that build a native tarball per platform have
  # no use for the binaries.
  #
  #     O11Y_PROXY_SKIP_BURRITO=1 MIX_ENV=prod mix release   # tarball only, no Zig needed
  defp release_steps do
    if System.get_env("O11Y_PROXY_SKIP_BURRITO") in ["1", "true"],
      do: [:assemble, &drop_dev_priv/1, :tar],
      else: [:assemble, &drop_dev_priv/1, :tar, &Burrito.wrap/1]
  end

  # Mix copies `priv/` into the release wholesale, and `priv/plts` is where the `dialyzer:`
  # config above parks its PLT cache — 12MB of build-host-specific analysis tables that
  # were going out in every published artifact. Runs before `:tar` so the tarball loses
  # them too.
  defp drop_dev_priv(release) do
    release.path |> Path.join("lib/o11y_proxy-*/priv/plts") |> Path.wildcard() |> rm_all()
    release
  end

  defp rm_all(paths), do: Enum.each(paths, &File.rm_rf!/1)

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
      {:adbc, "~> 0.12"},
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
