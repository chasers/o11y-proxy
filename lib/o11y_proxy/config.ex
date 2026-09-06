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
          server: %{port: pos_integer(), auth: :none | :token, distribution: boolean()},
          defaults: %{limit: pos_integer(), max_window: String.t(), timeout: String.t()},
          sources: [Source.t()]
        }

  @server_schema [
    port: [type: :pos_integer, default: 4000],
    auth: [type: {:in, ["none", "token"]}, default: "none"],
    distribution: [
      type: :boolean,
      default: true,
      doc:
        "let the CLI reach a running daemon over Erlang distribution on loopback " <>
          "(`.plans/07-cli.md`). Off means every CLI invocation runs in-process."
    ]
  ]

  @defaults_schema [
    limit: [type: :pos_integer, default: 50],
    max_window: [type: :string, default: "7d"],
    timeout: [type: :string, default: "30s"],
    max_bytes: [
      type: :pos_integer,
      default: 64_000,
      doc: "response byte ceiling before truncation (`.plans/04-cross-cutting.md`)"
    ],
    redact_keys: [
      type: {:list, :string},
      default: [],
      doc:
        "extra attribute keys to redact, on top of O11yProxy.Shaping's built-in list " <>
          "(authorization, password, token, api_key, cookie, set-cookie)"
    ]
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
         {:ok, interpolated} <- interpolate(raw) do
      build(interpolated)
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
    with {:ok, opts} <- to_opts(map, schema),
         {:ok, validated} <- validate(opts, schema) do
      {:ok, validated}
    else
      {:error, message} -> {:error, {:invalid_block, block_name, message}}
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
    with {:ok, opts} <- to_opts(rest, schema),
         {:ok, validated} <- validate(opts, schema) do
      {:ok, validated}
    else
      {:error, message} -> {:error, {:invalid_source_config, source_name, message}}
    end
  end

  # YAML gives string keys and NimbleOptions wants atoms — but `String.to_atom/1` here
  # would mint an atom for every key in a file the operator points us at, and atoms are
  # never garbage collected. So keys are *looked up* against the schema instead of
  # converted: a known key resolves to the atom the schema already defined, and an unknown
  # one is reported here rather than created. Same "unknown options" message NimbleOptions
  # would have produced, so the error reads identically either way.
  defp to_opts(map, schema) do
    known = Map.new(Keyword.keys(schema), &{Atom.to_string(&1), &1})

    case Enum.reject(Map.keys(map), &Map.has_key?(known, &1)) do
      [] ->
        {:ok, Enum.map(map, fn {key, value} -> {Map.fetch!(known, key), value} end)}

      unknown ->
        {:error,
         "unknown options #{inspect(Enum.sort(unknown))}, valid options are: " <>
           inspect(Keyword.keys(schema))}
    end
  end

  defp validate(opts, schema) do
    case NimbleOptions.validate(opts, schema) do
      {:ok, validated} -> {:ok, validated}
      {:error, %NimbleOptions.ValidationError{} = e} -> {:error, Exception.message(e)}
    end
  end

  @doc """
  Turns a `load/1` error into something a human can act on. Config problems are the most
  likely reason a first run fails — especially for someone who just downloaded a
  single-file binary — so these say what was wrong, where, and what to do about it,
  rather than leaking an Elixir tuple.
  """
  @spec format_error(term()) :: String.t()
  def format_error({:no_config_file, paths}) do
    """
    No config file found. Looked in:
    #{Enum.map_join(paths, "\n", &"  - #{&1}")}

    Create one of those, or point at a config with:
      O11Y_PROXY_CONFIG=/path/to/config.yaml

    The smallest config that starts the server (discovery endpoints work with no
    sources — /v1/sources, /openapi.json and /healthz all respond):

      server:
        port: 4000
      sources: []
    """
  end

  def format_error({:invalid_yaml, path, reason}) do
    """
    Could not parse #{path} as YAML.

    #{indent(describe_yaml_error(reason))}
    """
  end

  def format_error({:missing_env_var, var}) do
    """
    The config references ${#{var}}, but #{var} is not set in the environment.

    Secrets are env-var references so the config file itself never holds a credential.
    Set it before starting, e.g.:
      export #{var}=...
    """
  end

  def format_error({:invalid_block, block, message}) do
    """
    The `#{block}:` block in your config is invalid.

    #{indent(message)}
    """
  end

  def format_error({:invalid_source_config, name, message}) do
    """
    Source "#{name}" is misconfigured.

    #{indent(message)}

    Each backend validates its own keys — see the config reference in the README, or
    `mix run -e 'IO.inspect(O11yProxy.Backends.ClickHouse.config_schema())'` for the
    exact options a backend accepts.
    """
  end

  def format_error({:unknown_backend, name}) do
    known = O11yProxy.Backends.registry() |> Map.keys() |> Enum.sort() |> Enum.join(", ")

    """
    Unknown backend "#{name}".

    Known backends: #{known}
    """
  end

  def format_error({:invalid_signal, signal}) do
    """
    Invalid signal "#{signal}".

    A source's `signal:` must be one of: #{Enum.map_join(O11yProxy.Query.signals(), ", ", &to_string/1)}
    """
  end

  def format_error({:invalid_source_shape, raw}) do
    """
    A source entry is missing required keys. Every source needs at least `name`,
    `backend` and `signal`:

      sources:
        - name: app_logs
          backend: clickhouse
          signal: logs

    Got: #{inspect(raw)}
    """
  end

  def format_error({shape_error, value})
      when shape_error in [:invalid_config_shape, :invalid_sources_shape] do
    """
    The config file's structure is wrong (#{shape_error}). It should be a YAML mapping
    with optional `server:`/`defaults:` blocks and a `sources:` list.

    Got: #{inspect(value)}
    """
  end

  def format_error({:invalid_block_shape, block, value}) do
    """
    The `#{block}:` block should be a YAML mapping, got: #{inspect(value)}
    """
  end

  def format_error(reason), do: inspect(reason)

  defp describe_yaml_error(%YamlElixir.ParsingError{line: line, column: column, message: message}) do
    "line #{line}, column #{column}: #{message}"
  end

  defp describe_yaml_error(%{__exception__: true} = exception), do: Exception.message(exception)
  defp describe_yaml_error(reason), do: inspect(reason)

  defp indent(text) do
    text |> to_string() |> String.split("\n") |> Enum.map_join("\n", &("  " <> &1))
  end
end
