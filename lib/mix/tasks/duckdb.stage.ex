defmodule Mix.Tasks.Duckdb.Stage do
  @shortdoc "Builds DuckDB's native stack for Burrito's targets"

  @moduledoc """
  Stages everything the `s3` backend needs inside a single-file binary, into
  `_build/duckdb-natives/<burrito-triplet>/`, where `O11yProxy.Burrito.DuckDBNatives` picks
  it up during the release.

      mix duckdb.stage                 # every target this host can build
      mix duckdb.stage linux_aarch64   # just one

  Two kinds of target, with nothing in common but the destination.

  ## macOS — `macos_silicon`, and it must run on macOS

  Nothing is cross-compiled and nothing is bundled. A macOS host has already built adbc
  natively and linked it against its own libc++, which is why the macOS *tarball* has
  always had a working `s3` backend; the binaries lack one only because they are
  cross-compiled from Linux and so get Linux artifacts in the payload. This copies what the
  host built out of adbc's `priv` and adds `@loader_path` rpaths so the libraries find each
  other wherever Burrito unpacks them.

  There is no `macos_x86_64`: GitHub retired the Intel runners, and a native build needs a
  native host.

  ## Linux — `linux_x86_64`, `linux_aarch64`

  Burrito's ERTS is musl-linked, so nothing glibc can load inside a binary. Five pieces
  have to line up, and each one is a thing that was wrong the first time:

    * **`libduckdb`** — DuckDB publishes official musl builds, so this is a download, not a
      compile. It is renamed to the filename `adbc` looks for at runtime, which is
      `<runtime-triplet>-<version>-libadbc_driver_duckdb.so`; that triplet comes from
      `:erlang.system_info(:system_architecture)` *inside the binary*, which is not the
      same string Burrito uses for the build.
    * **`libstdc++` and `libgcc_s`** — DuckDB's musl build still links these dynamically,
      and a Burrito payload has no system libraries at all. Taken from Alpine, which is
      where musl builds of them live.
    * **adbc's driver manager and NIF** — cross-compiled here with `zig c++`, which links
      libc++ statically and so leaves no `libstdc++` dependency of its own. `make all`
      alone is not enough: adbc's `all:` target builds only the driver manager, so the NIF
      would silently stay the host's glibc one.
    * **RPATH** — the payload is unpacked to a cache directory that is on no loader search
      path, so every library gets `$ORIGIN` (and the NIF `$ORIGIN/lib`, since it sits a
      level up). Without this the driver manager loads and then `dlopen` of DuckDB fails
      looking for `libstdc++.so.6` that is sitting right next to it.
    * **Unique names** for the bundled `libstdc++`/`libgcc_s`, because musl searches
      `LD_LIBRARY_PATH` *before* rpath, so no rpath tagging can out-rank a host that
      exports one covering its own glibc copies. See `rename_support_libs/2`.

  Needs `cmake`, `zig` and `patchelf` for the Linux path; `install_name_tool` and
  `codesign` for the macOS one.
  """

  use Mix.Task

  @duckdb_version "1.5.1"
  @alpine "https://dl-cdn.alpinelinux.org/alpine/v3.21/main"
  @alpine_libstdcpp "libstdc++-14.2.0-r4.apk"
  @alpine_libgcc "libgcc-14.2.0-r4.apk"

  # burrito target => build inputs. `triplet` is what `Burrito.Builder.Target.make_triplet/1`
  # actually returns (no `-musl` suffix — it tests `qualifiers[:os]`, which is always nil
  # because `:os` is popped into the struct's own fields first). `runtime_triplet` is what
  # adbc computes inside the running binary, and the two genuinely differ.
  @targets %{
    "linux_aarch64" => %{
      kind: :linux_musl,
      triplet: "aarch64-linux",
      runtime_triplet: "aarch64-linux-musl",
      zig_target: "aarch64-linux-musl",
      duckdb_asset: "libduckdb-linux-arm64-musl.zip",
      alpine_arch: "aarch64"
    },
    "linux_x86_64" => %{
      kind: :linux_musl,
      triplet: "x86_64-linux",
      runtime_triplet: "x86_64-linux-musl",
      zig_target: "x86_64-linux-musl",
      duckdb_asset: "libduckdb-linux-amd64-musl.zip",
      alpine_arch: "x86_64"
    },
    # Nothing to cross-compile and nothing to bundle: a macOS host builds adbc natively
    # and links against its own libc++, which is why the macOS *tarball* has always had a
    # working `s3` backend. The binaries lack it only because they are cross-compiled from
    # Linux, so the payload gets Linux artifacts. Staging on a macOS runner and handing the
    # result to the Linux build is the whole fix.
    #
    # Must therefore be run *on* macOS. There is no `macos_x86_64` entry because GitHub
    # retired the Intel runners, and a native build needs a native host.
    "macos_silicon" => %{
      kind: :darwin_native,
      triplet: "aarch64-macos"
    }
  }

  @impl Mix.Task
  def run(args) do
    # Deliberately not `app.start` — this is a build task and booting the proxy to
    # download files would start a listener on the build host.
    Mix.Task.run("loadpaths")
    :ok = Application.ensure_started(:inets)
    :ok = Application.ensure_started(:ssl)

    names = if args == [], do: Map.keys(@targets), else: args

    Enum.each(names, fn name ->
      target = Map.get(@targets, name) || Mix.raise("unknown target #{name}")
      ensure_tools!(target.kind)
      stage(name, target)
    end)
  end

  defp stage(name, target) do
    dir = Path.join(["_build", "duckdb-natives", target.triplet])
    Mix.shell().info("staging #{name} -> #{dir}")

    File.rm_rf!(dir)
    File.mkdir_p!(dir)

    stage_kind(target.kind, dir, target)

    Mix.shell().info("staged #{name}")
  end

  defp stage_kind(:linux_musl, dir, target) do
    duckdb_driver(dir, target)
    support_libs(dir, target)
    adbc_natives(dir, target)
    rename_support_libs(dir, target)
    set_rpaths(dir)
  end

  # The artifacts are already on this machine: `mix deps.compile adbc` built the NIF and
  # the driver manager for this host, and adbc downloaded DuckDB's macOS library under the
  # filename it looks for at runtime. Copy them out of adbc's priv and re-point their load
  # paths at wherever Burrito unpacks the payload.
  defp stage_kind(:darwin_native, dir, _target) do
    priv = adbc_priv_dir()

    nif = Path.join(priv, "adbc_nif.so")

    File.exists?(nif) ||
      Mix.raise("no adbc_nif.so at #{priv} — run `mix deps.compile adbc` first")

    File.cp!(nif, Path.join(dir, "adbc_nif.so"))

    libs = priv |> Path.join("lib/*") |> Path.wildcard() |> Enum.filter(&File.regular?/1)

    libs == [] && Mix.raise("no libraries at #{priv}/lib — is the :duckdb driver configured?")

    Enum.each(libs, &File.cp!(&1, Path.join(dir, Path.basename(&1))))

    set_darwin_load_paths(dir)
  end

  defp adbc_priv_dir do
    # `Application.app_dir/2` needs the app loaded; this task deliberately does not start
    # it, and the path is derivable anyway.
    Path.join([Mix.Project.build_path(), "lib", "adbc", "priv"])
  end

  # macOS has no `$ORIGIN`; the equivalent is `@loader_path`. Adding it as an LC_RPATH
  # entry makes any `@rpath/…` install name in these libraries resolve next to whichever
  # one is doing the loading, which is what Burrito's unpack location requires.
  #
  # `-add_rpath` fails if the entry is already present, and that is fine rather than fatal.
  #
  # Re-signing after is not optional on Apple silicon: editing a Mach-O invalidates its
  # signature, and arm64 macOS refuses to load an image whose signature does not verify.
  # An ad-hoc signature (`-`) is enough — this is not about notarization, only about the
  # binary being intact.
  defp set_darwin_load_paths(dir) do
    for file <- Path.wildcard(Path.join(dir, "*")), File.regular?(file) do
      rpath =
        if Path.basename(file) == "adbc_nif.so", do: "@loader_path/lib", else: "@loader_path"

      _ = System.cmd("install_name_tool", ["-add_rpath", rpath, file], stderr_to_stdout: true)

      case System.cmd("codesign", ["--force", "--sign", "-", file], stderr_to_stdout: true) do
        {_, 0} -> :ok
        {out, code} -> Mix.raise("codesign failed on #{file} (#{code})\n#{out}")
      end
    end
  end

  defp duckdb_driver(dir, target) do
    zip =
      download(
        "https://github.com/duckdb/duckdb/releases/download/v#{@duckdb_version}/#{target.duckdb_asset}",
        target.duckdb_asset
      )

    {:ok, _} =
      :zip.unzip(String.to_charlist(zip), [
        {:file_list, [~c"libduckdb.so"]},
        {:cwd, String.to_charlist(dir)}
      ])

    File.rename!(
      Path.join(dir, "libduckdb.so"),
      Path.join(dir, "#{target.runtime_triplet}-#{@duckdb_version}-libadbc_driver_duckdb.so")
    )
  end

  defp support_libs(dir, target) do
    for apk <- [@alpine_libstdcpp, @alpine_libgcc] do
      path = download("#{@alpine}/#{target.alpine_arch}/#{apk}", "#{target.alpine_arch}-#{apk}")
      extract_dir = Path.join(System.tmp_dir!(), "o11y-apk-#{:erlang.phash2({apk, dir})}")
      File.rm_rf!(extract_dir)
      File.mkdir_p!(extract_dir)

      # An .apk is three concatenated gzip streams (signature, control, data), not one.
      # `:erl_tar` reads the first and stops, silently producing nothing; GNU tar follows
      # all three. Non-zero exit is expected — it complains about the signature members —
      # so the check is whether the files we wanted actually appeared.
      _ = System.cmd("tar", ["xzf", Path.expand(path)], cd: extract_dir, stderr_to_stdout: true)

      found =
        extract_dir
        |> Path.join("usr/lib/lib{stdc++,gcc_s}.so*")
        |> Path.wildcard()
        |> Enum.filter(&File.regular?/1)

      found == [] && Mix.raise("no libraries extracted from #{apk}")

      Enum.each(found, &File.cp!(&1, Path.join(dir, soname(&1))))
    end
  end

  # libstdc++.so.6.0.33 has to land as the soname DuckDB's DT_NEEDED asks for.
  defp soname(path) do
    if String.contains?(Path.basename(path), "stdc++"),
      do: "libstdc++.so.6",
      else: "libgcc_s.so.1"
  end

  defp adbc_natives(dir, target) do
    adbc = Path.join("deps", "adbc")
    build = Path.join(System.tmp_dir!(), "o11y-adbc-#{target.zig_target}")
    toolchain = Path.expand(Path.join(["build", "cross", "#{target.zig_target}.cmake"]))

    File.rm_rf!(build)
    File.mkdir_p!(build)

    env = [
      {"CMAKE_TOOLCHAIN_FILE", toolchain},
      {"MIX_APP_PATH", build},
      {"ERTS_INCLUDE_DIR", erts_include_dir()},
      # adbc's own mix.exs supplies this via `make_env`; running its Makefile directly
      # does not, and CMake fails with "include_directories given empty-string".
      {"FINE_INCLUDE_DIR", Path.expand(Path.join(["deps", "fine", "c_include"]))},
      {"DEFAULT_JOBS", "#{System.schedulers_online()}"}
    ]

    # `build`, not `all`: `all:` stops at the driver manager and never produces adbc_nif.so.
    case System.cmd("make", ["build"], cd: adbc, env: env, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, code} -> Mix.raise("adbc cross-build failed (#{code})\n#{out}")
    end

    File.cp!(Path.join(build, "priv/adbc_nif.so"), Path.join(dir, "adbc_nif.so"))

    # Copy the driver manager under its soname; the NIF's DT_NEEDED asks for `.so.110`,
    # and the build leaves that as a symlink chain onto `.so.110.0.0`.
    manager =
      build
      |> Path.join("priv/lib/libadbc_driver_manager.so.*.*")
      |> Path.wildcard()
      |> List.first() ||
        Mix.raise("no libadbc_driver_manager built for #{target.zig_target}")

    File.cp!(manager, Path.join(dir, "libadbc_driver_manager.so.110"))
  end

  # Bundled `libstdc++.so.6` and `libgcc_s.so.1` get unique names, and every DT_NEEDED
  # referring to them is rewritten to match.
  #
  # This is the part that actually makes them win, and the reason is a musl/glibc
  # difference worth knowing: **musl searches `LD_LIBRARY_PATH` before rpath**, where glibc
  # searches DT_RPATH first. So on musl no rpath tagging can out-rank a build or run host
  # that exports an `LD_LIBRARY_PATH` covering its own glibc `libstdc++.so.6` — the process
  # loads that one and dies relocating it (`arc4random: symbol not found`). GitHub's
  # runners do exactly this, which is why the first CI run failed against artifacts that
  # worked on a developer machine.
  #
  # A name nothing else on any system publishes cannot be shadowed: the `LD_LIBRARY_PATH`
  # sweep misses, and the search falls through to our `$ORIGIN`.
  @renames %{
    "libstdc++.so.6" => "libo11y_stdcxx.so.6",
    "libgcc_s.so.1" => "libo11y_gcc_s.so.1"
  }

  defp rename_support_libs(dir, target) do
    # Every ELF here that might name one of them: DuckDB needs both, and the bundled
    # libstdc++ itself needs libgcc_s.
    consumers = [
      Path.join(dir, "#{target.runtime_triplet}-#{@duckdb_version}-libadbc_driver_duckdb.so")
      | Enum.map(Map.keys(@renames), &Path.join(dir, &1))
    ]

    for file <- consumers, File.exists?(file), {from, to} <- @renames do
      patchelf!(["--replace-needed", from, to, file])
    end

    for {from, to} <- @renames do
      source = Path.join(dir, from)
      File.exists?(source) && File.rename!(source, Path.join(dir, to))
    end
  end

  # The NIF sits at priv/ and everything else at priv/lib/, so they need different
  # origins. Burrito unpacks the payload somewhere the loader knows nothing about.
  defp set_rpaths(dir) do
    dir
    |> Path.join("*.so*")
    |> Path.wildcard()
    |> Enum.each(fn file ->
      rpath = if Path.basename(file) == "adbc_nif.so", do: "$ORIGIN/lib", else: "$ORIGIN"

      # DT_RPATH rather than patchelf's default DT_RUNPATH. This is not what makes the
      # bundled libraries win — see `rename_support_libs/1` for that — but it is the right
      # tag to write, and it matters if these are ever loaded by glibc, which does consult
      # DT_RPATH ahead of LD_LIBRARY_PATH.
      patchelf!(["--force-rpath", "--set-rpath", rpath, file])
    end)
  end

  defp patchelf!(args) do
    case System.cmd("patchelf", args, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, code} -> Mix.raise("patchelf #{Enum.join(args, " ")} failed (#{code})\n#{out}")
    end
  end

  defp download(url, name) do
    cache = Path.join(["_build", "duckdb-natives", "_cache"])
    File.mkdir_p!(cache)
    path = Path.join(cache, name)

    if File.exists?(path) do
      path
    else
      Mix.shell().info("  downloading #{name}")

      case :httpc.request(:get, {String.to_charlist(url), []}, [{:autoredirect, true}],
             body_format: :binary
           ) do
        {:ok, {{_, 200, _}, _headers, body}} ->
          File.write!(path, body)
          path

        other ->
          Mix.raise("could not download #{url}: #{inspect(other)}")
      end
    end
  end

  defp erts_include_dir do
    Path.join([to_string(:code.root_dir()), "erts-#{:erlang.system_info(:version)}", "include"])
  end

  # Per-kind, because they share nothing: the Linux targets cross-compile and rewrite ELF,
  # the macOS one copies what its own host already built and rewrites Mach-O.
  defp ensure_tools!(:linux_musl), do: require_tools!(["cmake", "zig", "patchelf"])
  defp ensure_tools!(:darwin_native), do: require_tools!(["install_name_tool", "codesign"])

  defp require_tools!(tools) do
    Enum.each(tools, fn tool ->
      System.find_executable(tool) || Mix.raise("#{tool} is required by mix duckdb.stage")
    end)
  end
end
