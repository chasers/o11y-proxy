defmodule O11yProxy.Config do
  @moduledoc """
  Loads and validates `./o11y.yaml` (or `~/.config/o11y-proxy/config.yaml`, overridable via
  `O11Y_PROXY_CONFIG`). Secrets are `${ENV_VAR}` references only — the file itself is safe
  to commit, and never holds a literal credential. Each source's adapter-specific fields
  are validated by that adapter's own `config_schema/0` via NimbleOptions, so a typo in a
  source config fails at boot with a precise message. See `.plans/02-backend-behaviour.md`.
  """

  alias O11yProxy.Config.Source

  @enforce_keys [:server, :defaults, :sources]
  defstruct [:server, :defaults, :sources]

  @type t :: %__MODULE__{
          server: %{port: pos_integer(), auth: :none | :token},
          defaults: %{limit: pos_integer(), max_window: String.t(), timeout: String.t()},
          sources: [Source.t()]
        }

  @server_schema [
    port: [type: :pos_integer, default: 4000],
    auth: [type: {:in, ["none", "token"]}, default: "none"]
  ]

  @defaults_schema [
    limit: [type: :pos_integer, default: 50],
    max_window: [type: :string, default: "7d"],
    timeout: [type: :string, default: "30s"]
  ]

  @doc "Loads config, raising with a precise message on any failure. Meant for boot."
  @spec load!(keyword()) :: t()
  def load!(opts \\ []) do
    case load(opts) do
      {:ok, config} -> config
      {:error, reason} -> raise "o11y-proxy config error: #{format_error(reason)}"
    end
  end

  @spec load(keyword()) :: {:ok, t()} | {:error, term()}
  def load(opts \\ []) do
    with {:ok, path} <- resolve_path(opts),
         {:ok, raw} <- read_yaml(path),
         {:ok, interpolated} <- interpolate(raw),
         {:ok, config} <- build(interpolated) do
      {:ok, config}
    end
  end

  # -- path resolution -----------------------------------------------------------------

  # An explicit :path opt or O11Y_PROXY_CONFIG is authoritative — if given but missing,
  # that's an error, not a silent fall-through to the next default location.
  defp resolve_path(opts) do
    default_home = Path.expand("~/.config/o11y-proxy/config.yaml")

    case Keyword.get(opts, :path) || System.get_env("O11Y_PROXY_CONFIG") do
      nil ->
        cond do
          File.exists?("./o11y.yaml") -> {:ok, "./o11y.yaml"}
          File.exists?(default_home) -> {:ok, default_home}
          true -> {:error, {:no_config_file, ["./o11y.yaml", default_home]}}
        end

      explicit ->
        if File.exists?(explicit),
          do: {:ok, explicit},
          else: {:error, {:no_config_file, [explicit]}}
    end
  end

  defp read_yaml(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, data} -> {:ok, data || %{}}
      {:error, reason} -> {:error, {:invalid_yaml, path, reason}}
    end
  end

  # -- ${ENV_VAR} interpolation ---------------------------------------------------------
  #
  # Secrets never touch the config file or logs — every value here was either literal
  # (safe to commit) or a reference resolved from the environment at load time.

  @env_re ~r/\$\{([A-Za-z_][A-Za-z0-9_]*)\}/

  defp interpolate(data) do
    {:ok, do_interpolate(data)}
  catch
    {:missing_env_var, var} -> {:error, {:missing_env_var, var}}
  end

  defp do_interpolate(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {k, do_interpolate(v)} end)
  end

  defp do_interpolate(list) when is_list(list), do: Enum.map(list, &do_interpolate/1)

  defp do_interpolate(str) when is_binary(str) do
    Regex.replace(@env_re, str, fn _whole, var ->
      case System.fetch_env(var) do
        {:ok, value} -> value
        :error -> throw({:missing_env_var, var})
      end
    end)
  end

  defp do_interpolate(other), do: other

  # -- structural validation -------------------------------------------------------------

  defp build(data) when is_map(data) do
    with {:ok, server} <- validate_block(Map.get(data, "server", %{}), @server_schema, :server),
         {:ok, defaults} <-
           validate_block(Map.get(data, "defaults", %{}), @defaults_schema, :defaults),
         {:ok, sources} <- build_sources(Map.get(data, "sources", []) || []) do
      {:ok,
       %__MODULE__{
         server: server |> Map.new() |> Map.update!(:auth, &auth_atom/1),
         defaults: Map.new(defaults),
         sources: sources
       }}
    end
  end

  defp build(other), do: {:error, {:invalid_config_shape, other}}

  defp auth_atom("none"), do: :none
  defp auth_atom("token"), do: :token

  defp validate_block(map, schema, block_name) when is_map(map) do
    opts = for {k, v} <- map, into: [], do: {String.to_atom(k), v}

    case NimbleOptions.validate(opts, schema) do
      {:ok, validated} ->
        {:ok, validated}

      {:error, %NimbleOptions.ValidationError{} = e} ->
        {:error, {:invalid_block, block_name, Exception.message(e)}}
    end
  end

  defp validate_block(other, _schema, block_name),
    do: {:error, {:invalid_block_shape, block_name, other}}

  defp build_sources(sources) when is_list(sources) do
    sources
    |> Enum.reduce_while({:ok, []}, fn raw, {:ok, acc} ->
      case build_source(raw) do
        {:ok, source} -> {:cont, {:ok, [source | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp build_sources(other), do: {:error, {:invalid_sources_shape, other}}

  defp build_source(%{"name" => name, "backend" => backend_name, "signal" => signal} = raw)
       when is_binary(name) and is_binary(backend_name) and is_binary(signal) do
    with {:ok, backend} <- O11yProxy.Backends.resolve(backend_name),
         {:ok, signal_atom} <- parse_signal(signal),
         rest <- Map.drop(raw, ["name", "backend", "signal"]),
         schema <- backend.config_schema(),
         {:ok, opts} <- validate_source_opts(rest, schema, name) do
      {:ok,
       %Source{
         name: name,
         backend: backend,
         backend_name: backend_name,
         signal: signal_atom,
         opts: Map.new(opts)
       }}
    end
  end

  defp build_source(raw), do: {:error, {:invalid_source_shape, raw}}

  defp parse_signal(str) do
    case Enum.find(O11yProxy.Query.signals(), &(Atom.to_string(&1) == str)) do
      nil -> {:error, {:invalid_signal, str}}
      signal -> {:ok, signal}
    end
  end

  defp validate_source_opts(rest, schema, source_name) do
    opts = for {k, v} <- rest, into: [], do: {String.to_atom(k), v}

    case NimbleOptions.validate(opts, schema) do
      {:ok, validated} ->
        {:ok, validated}

      {:error, %NimbleOptions.ValidationError{} = e} ->
        {:error, {:invalid_source_config, source_name, Exception.message(e)}}
    end
  end

  defp format_error(reason), do: inspect(reason)
end
