defmodule O11yProxy.Burrito.DuckDBNatives do
  @moduledoc """
  Build-time only. A `Burrito.Builder.Step` that decides, per target, what DuckDB the
  single-file binary carries.

  Burrito's ERTS is musl-linked, so the glibc NIF `adbc` ships by default cannot load
  inside a binary — see `README.md`, "Building the binaries". For a target we have musl
  artifacts staged for, this swaps them in; for every other target it strips the native
  half entirely, because ~25MB of `libduckdb` that can never load is worse than nothing.

  Artifacts are staged under `_build/duckdb-musl/<triplet>/` by `mix duckdb.stage`, which
  is the piece that knows the download URLs. This step only moves files, so a release can
  be built offline once they are staged.

  It runs `post` the `:patch` phase, after `Burrito.Steps.Patch.RecompileNIFs`, so it has
  the last word on the contents of `priv/`.
  """

  @behaviour Burrito.Builder.Step

  alias Burrito.Builder.Log
  alias Burrito.Builder.Target

  @impl Burrito.Builder.Step
  def execute(context) do
    priv = adbc_priv(context.work_dir)
    triplet = Target.make_triplet(context.target)

    cond do
      is_nil(priv) ->
        context

      File.dir?(staging_dir(triplet)) ->
        install(priv, triplet)
        context

      true ->
        strip(priv, triplet)
        context
    end
  end

  @doc "Where `mix duckdb.stage` puts a target's musl artifacts."
  @spec staging_dir(String.t()) :: String.t()
  def staging_dir(triplet), do: Path.join(["_build", "duckdb-musl", triplet])

  defp adbc_priv(work_dir) do
    work_dir |> Path.join("lib/adbc-*/priv") |> Path.wildcard() |> List.first()
  end

  defp install(priv, triplet) do
    Log.info(:step, "Installing musl DuckDB natives for #{triplet}")

    File.rm_rf!(Path.join(priv, "lib"))
    File.rm_rf!(Path.join(priv, "include"))
    File.mkdir_p!(Path.join(priv, "lib"))

    triplet
    |> staging_dir()
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.each(fn source ->
      # adbc_nif.so sits at priv/, everything it links against at priv/lib/.
      destination =
        if Path.basename(source) == "adbc_nif.so",
          do: Path.join(priv, "adbc_nif.so"),
          else: Path.join([priv, "lib", Path.basename(source)])

      File.cp!(source, destination)
    end)
  end

  defp strip(priv, triplet) do
    Log.info(:step, "No musl DuckDB staged for #{triplet} — stripping natives")

    File.rm_rf!(Path.join(priv, "lib"))
    File.rm_rf!(Path.join(priv, "include"))
  end
end
