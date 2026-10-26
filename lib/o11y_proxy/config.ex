defmodule O11yProxy.Config do
  @moduledoc """
  Loads and validates `./o11y.yaml` (or `~/.config/o11y-proxy/config.yaml`, overridable via
  `O11Y_PROXY_CONFIG`). Secrets are `${ENV_VAR}` references only — the file itself is safe
  to commit, and never holds a literal credential. Each source's adapter-specific fields
  are validated by that adapter's own `config_schema/0` via NimbleOptions, so a typo in a
  source config fails at boot with a precise message.
  """

  alias O11yProxy.Auth.SPIFFE
  alias O11yProxy.Config.{Policies, Source}

  @enforce_keys [:server, :defaults, :sources]
  defstruct [:server, :defaults, :sources, policies: %{}]

  @type t :: %__MODULE__{
          server: %{
            port: pos_integer(),
            bind: :inet.ip_address(),
            auth: :none | :token | :oidc,
            distribution: boolean(),
            oidc: map() | nil
          },
          defaults: %{limit: pos_integer(), max_window: String.t(), timeout: String.t()},
          sources: [Source.t()],
          policies: %{optional(String.t()) => O11yProxy.Policy.t()}
        }

  @server_schema [
    port: [type: :pos_integer, default: 4000],
    bind: [
      type: :string,
      default: "127.0.0.1",
      doc: "address to listen on. Anything but loopback needs auth: token or auth: oidc."
    ],
    auth: [type: {:in, ["none", "token", "oidc"]}, default: "none"],
    distribution: [
      type: :boolean,
      default: true,
      doc:
        "let the CLI reach a running daemon over Erlang distribution on loopback. Off " <>
          "means every CLI invocation runs in-process."
    ]
  ]

  @oidc_schema [
    issuer: [
      type: :string,
      required: true,
      doc: "the exact `iss` of accepted tokens; discovery is fetched from under it"
    ],
    audience: [
      type: {:or, [:string, {:list, :string}]},
      required: true,
      doc: "a token's `aud` must contain one of these"
    ],
    jwks_uri: [
      type: :string,
      doc:
        "fetch keys from here and skip discovery, for issuers that publish no discovery document"
    ],
    algorithms: [
      type: {:list, {:in, O11yProxy.Auth.OIDC.Verifier.supported_algorithms()}},
      doc: "accepted signing algorithms; default is what discovery advertises, else RS256"
    ],
    jwks_refresh_seconds: [type: :pos_integer, default: 300],
    leeway_seconds: [
      type: :non_neg_integer,
      default: 60,
      doc: "clock skew tolerated on exp and nbf"
    ],
    identity_claim: [type: :string, default: "sub", doc: "claim path that names the caller"],
    role_claim: [type: :string, doc: "claim path holding the caller's role, a string or list"],
    default_policy: [type: :string, doc: "policy for a token whose roles match none"]
  ]

  @spiffe_schema [
    trust_domain: [
      type: :string,
      required: true,
      doc: "the trust domain a role_claim SPIFFE ID must be in, e.g. example.org"
    ],
    paths: [
      type: {:list, :any},
      required: true,
      doc: "entries of ID patterns that mean the same thing, each with its policy_names"
    ]
  ]

  @spiffe_path_schema [
    patterns: [
      type: {:list, :string},
      required: true,
      doc:
        "ID paths such as /aws/{account}/*/role/{role}, all meaning the same thing; see " <>
          "O11yProxy.Auth.SPIFFE"
    ],
    policy_names: [
      type: {:list, :string},
      required: true,
      doc: "templates such as \"{account}/{role}\", filled from a match and tried in order"
    ]
  ]

  @defaults_schema [
    limit: [type: :pos_integer, default: 50],
    max_window: [type: :string, default: "7d"],
    timeout: [type: :string, default: "30s"],
    max_bytes: [
      type: :pos_integer,
      default: 64_000,
      doc: "response byte ceiling before truncation"
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
    {oidc_raw, server_raw} = split_oidc(Map.get(data, "server", %{}))

    with {:ok, server} <- validate_block(server_raw, @server_schema, :server),
         {:ok, server} <- finish_server(Map.new(server)),
         {:ok, oidc} <- build_oidc(oidc_raw),
         {:ok, defaults} <-
           validate_block(Map.get(data, "defaults", %{}), @defaults_schema, :defaults),
         {:ok, sources} <- build_sources(Map.get(data, "sources", []) || []),
         {:ok, policies} <-
           Policies.build(
             Map.get(data, "policies") || %{},
             Enum.map(sources, & &1.name)
           ),
         :ok <- check_auth(server, oidc, policies) do
      {:ok,
       %__MODULE__{
         server: Map.put(server, :oidc, oidc),
         defaults: Map.new(defaults),
         sources: sources,
         policies: policies
       }}
    end
  end

  defp build(other), do: {:error, {:invalid_config_shape, other}}

  # `oidc:` is a nested mapping, and `to_opts/2` only looks one level deep, so it is taken
  # out and validated as a block of its own.
  defp split_oidc(server) when is_map(server), do: Map.pop(server, "oidc")
  defp split_oidc(server), do: {nil, server}

  defp finish_server(server) do
    case :inet.parse_address(String.to_charlist(server.bind)) do
      {:ok, address} ->
        {:ok, %{server | bind: address, auth: auth_atom(server.auth)}}

      {:error, _} ->
        {:error, {:invalid_block, :server, "bind #{inspect(server.bind)} is not an IP address"}}
    end
  end

  defp auth_atom("none"), do: :none
  defp auth_atom("token"), do: :token
  defp auth_atom("oidc"), do: :oidc

  defp build_oidc(nil), do: {:ok, nil}

  defp build_oidc(raw) do
    # Fetched rather than popped-with-default: a `spiffe:` key whose children are all
    # commented out is YAML null, and reading that as "not configured" would quietly turn
    # the role claim back into a literal role name.
    {spiffe_raw, raw} =
      case is_map(raw) && Map.fetch(raw, "spiffe") do
        {:ok, value} -> {{:set, value}, Map.delete(raw, "spiffe")}
        _ -> {:unset, raw}
      end

    with {:ok, oidc} <- validate_block(raw, @oidc_schema, "server.oidc"),
         {:ok, spiffe} <- build_spiffe(spiffe_raw) do
      oidc = oidc |> Map.new() |> Map.update!(:audience, &List.wrap/1)
      {:ok, if(spiffe, do: Map.put(oidc, :spiffe, spiffe), else: oidc)}
    end
  end

  defp build_spiffe(:unset), do: {:ok, nil}

  defp build_spiffe({:set, raw}) do
    with {:ok, opts} <- validate_block(raw, @spiffe_schema, "server.oidc.spiffe"),
         {:ok, paths} <- spiffe_paths(opts[:paths]),
         {:ok, spiffe} <- SPIFFE.compile(opts[:trust_domain], paths) do
      {:ok, spiffe}
    else
      {:error, message} when is_binary(message) ->
        {:error, {:invalid_block, "server.oidc.spiffe", message}}

      {:error, _reason} = error ->
        error
    end
  end

  # Each entry is its own block, named by index, so an error says which one is wrong —
  # the same `paths[i]` that `SPIFFE.compile/2` uses for the errors it finds.
  defp spiffe_paths(entries) do
    entries
    |> Enum.with_index()
    |> map_ok(fn {entry, index} ->
      with {:ok, opts} <-
             validate_block(entry, @spiffe_path_schema, "server.oidc.spiffe.paths[#{index}]"),
           do: {:ok, {opts[:patterns], opts[:policy_names]}}
    end)
  end

  defp map_ok(list, fun) do
    list
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  # The combinations that would boot but not do what the operator meant. Each of these
  # is a misconfiguration that fails *open* or silently, so it is refused at load rather
  # than discovered in production.
  defp check_auth(server, oidc, policies) do
    with :ok <- check_bind(server),
         :ok <- check_oidc_block(server.auth, oidc) do
      check_policies(server.auth, oidc, policies)
    end
  end

  defp check_bind(%{auth: :none, bind: bind}) do
    if loopback?(bind) do
      :ok
    else
      server_error(
        "bind #{:inet.ntoa(bind)} accepts connections from other machines, " <>
          "which needs auth: token or auth: oidc"
      )
    end
  end

  defp check_bind(_server), do: :ok

  defp check_oidc_block(:oidc, nil),
    do: server_error("auth: oidc needs a server.oidc block with at least issuer and audience")

  defp check_oidc_block(auth, oidc) when auth != :oidc and not is_nil(oidc),
    do: server_error("server.oidc is set but auth is #{auth}; set auth: oidc to use it")

  defp check_oidc_block(_auth, _oidc), do: :ok

  defp check_policies(:oidc, oidc, policies), do: check_oidc_policies(oidc, policies)
  defp check_policies(_auth, _oidc, policies) when policies == %{}, do: :ok

  defp check_policies(auth, _oidc, _policies) do
    {:error,
     {:invalid_block, :policies,
      "policies are only enforced for auth: oidc, and auth is #{auth}. " <>
        "Remove them or set auth: oidc, so access is never assumed to be limited " <>
        "when it is not."}}
  end

  defp check_oidc_policies(oidc, policies) do
    default = Map.get(oidc, :default_policy)
    defined = policies |> Map.keys() |> Enum.sort() |> Enum.join(", ")

    cond do
      policies == %{} ->
        {:error,
         {:invalid_block, :policies,
          "auth: oidc needs at least one policy. For \"any valid token may query " <>
            "everything\", define one with sources: \"*\" and name it as default_policy."}}

      Map.has_key?(oidc, :spiffe) and is_nil(Map.get(oidc, :role_claim)) ->
        {:error,
         {:invalid_block, "server.oidc",
          "spiffe: reads its SPIFFE ID from role_claim, so set role_claim (usually sub)"}}

      is_nil(Map.get(oidc, :role_claim)) and is_nil(default) ->
        {:error,
         {:invalid_block, "server.oidc",
          "set role_claim, default_policy, or both, so a token can be mapped to a policy"}}

      not is_nil(default) and not Map.has_key?(policies, default) ->
        {:error,
         {:invalid_block, "server.oidc",
          "default_policy #{inspect(default)} is not defined under policies " <>
            "(defined: #{defined})"}}

      true ->
        check_reachable(oidc, policies)
    end
  end

  # With spiffe:, a policy is selected only by a filled-in policy_names template or as
  # the default. One that no template can produce is dead config — a typo like
  # `111122223333:sre` for `{account}/{role}` — and would never show up as an error, just
  # as callers quietly getting a different policy. A typo that still fits some template
  # (`111122223333_sre` fits `{role}`) cannot be told apart from a real name, and that is
  # the case the docs' advice to keep role-only policies small is for.
  defp check_reachable(%{spiffe: spiffe} = oidc, policies) do
    default = Map.get(oidc, :default_policy)

    unreachable =
      for name <- Enum.sort(Map.keys(policies)),
          name != default and not SPIFFE.produces?(spiffe, name),
          do: name

    case unreachable do
      [] ->
        :ok

      names ->
        {:error,
         {:invalid_block, :policies,
          "no spiffe policy_names template can produce #{Enum.map_join(names, ", ", &inspect/1)}, " <>
            "so no token could ever be given it. Rename it to match a template, or make it " <>
            "the default_policy."}}
    end
  end

  defp check_reachable(_oidc, _policies), do: :ok

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?(_address), do: false

  defp server_error(message), do: {:error, {:invalid_block, :server, message}}

  @doc false
  # Shared with `O11yProxy.Config.Policies`, so every block in the file is validated, and
  # reports an unknown key, the same way.
  @spec validate_block(term(), keyword(), atom() | String.t()) ::
          {:ok, keyword()} | {:error, term()}
  def validate_block(map, schema, block_name) when is_map(map) do
    with {:ok, opts} <- to_opts(map, schema),
         {:ok, validated} <- validate(opts, schema) do
      {:ok, validated}
    else
      {:error, message} -> {:error, {:invalid_block, block_name, message}}
    end
  end

  def validate_block(other, _schema, block_name),
    do: {:error, {:invalid_block_shape, block_name, other}}

  defp build_sources(sources) when is_list(sources), do: map_ok(sources, &build_source/1)

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
