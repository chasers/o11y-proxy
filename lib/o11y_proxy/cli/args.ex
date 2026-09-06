defmodule O11yProxy.CLI.Args do
  @moduledoc """
  argv → a command and the string-keyed request map the core already takes.

  Pure on purpose. The CLI's interesting failure modes are all in argument handling —
  an operator token shadowing another, an unknown flag, a missing required value — and
  none of them need a BEAM with sources booted to exercise. Same seam discipline as
  `O11yProxy.Backends.ClickHouse.SQL` and `O11yProxy.Backends.Sentry.Search`: build the
  request here, execute it elsewhere.

  The request maps this produces are the *same* shape `POST /v1/query` and
  `POST /v1/context` receive, so `O11yProxy.Query.parse/2` and
  `O11yProxy.Context.resolve/2` validate CLI input and HTTP input identically. The CLI
  deliberately does not re-implement "from must be before to" or "exactly one of
  trace_id/error_id/service" — those live in the core and stay in one place.
  """

  @type command :: %{
          required(:command) => :serve | :query | :context | :sources | :schema | :health,
          required(:request) => map(),
          required(:pretty) => boolean(),
          required(:quiet) => boolean()
        }

  # Longest token first, so `!=`, `>=`, `<=` and `=~` are never shadowed by the `=` that
  # sits inside or beside them. Order within a length doesn't matter — no two tokens of
  # the same length share a prefix.
  @filter_ops [
    {"!=", "neq"},
    {">=", "gte"},
    {"<=", "lte"},
    {"=~", "regex"},
    {"=", "eq"},
    {"~", "contains"}
  ]

  @query_switches [
    source: :string,
    signal: :string,
    from: :string,
    to: :string,
    mode: :string,
    limit: :integer,
    order: :string,
    filter: :keep,
    raw: :string,
    cursor: :string,
    pretty: :boolean,
    quiet: :boolean
  ]

  @context_switches [
    trace_id: :string,
    error_id: :string,
    service: :string,
    from: :string,
    to: :string,
    pretty: :boolean,
    quiet: :boolean
  ]

  @plain_switches [pretty: :boolean, quiet: :boolean]

  @doc """
  Parses argv.

  Returns `{:ok, command}` for something to run, `{:print, text}` for `--help`/`--version`
  (which this module owns: if control ever reached `Kernel.CLI` it would swallow them),
  or `{:error, message}` for a usage error the caller prints to
  stderr before exiting 1.
  """
  @spec parse([String.t()]) :: {:ok, command()} | {:print, String.t()} | {:error, String.t()}
  def parse(argv) when is_list(argv) do
    cond do
      Enum.any?(argv, &(&1 in ["-h", "--help"])) -> {:print, help_text()}
      Enum.any?(argv, &(&1 in ["-v", "--version"])) -> {:print, version_text()}
      true -> command(argv)
    end
  end

  # No arguments at all is the server — today's behavior, and the one an existing user
  # already has in a systemd unit or a terminal tab.
  defp command([]), do: {:ok, base(:serve, %{})}
  defp command(["serve"]), do: {:ok, base(:serve, %{})}

  defp command(["serve" | rest]),
    do: {:error, "serve takes no arguments, got: #{Enum.join(rest, " ")}"}

  defp command(["query" | rest]), do: query(rest)
  defp command(["context" | rest]), do: context(rest)
  defp command(["sources" | rest]), do: plain(:sources, rest)
  defp command(["health" | rest]), do: plain(:health, rest)
  defp command(["schema" | rest]), do: schema(rest)

  defp command([other | _]) do
    {:error,
     "unknown command: #{other}\n\nRun `o11y-proxy --help` for the commands this accepts."}
  end

  defp query(argv) do
    with {:ok, opts} <- switches(argv, @query_switches, "query"),
         {:ok, source} <- required(opts, :source, "query"),
         {:ok, signal} <- required(opts, :signal, "query"),
         {:ok, from} <- required(opts, :from, "query"),
         {:ok, to} <- required(opts, :to, "query"),
         {:ok, filters} <- filters(opts) do
      request =
        %{
          "sources" => [source],
          "signal" => signal,
          "from" => from,
          "to" => to,
          "filters" => filters
        }
        |> put_present("mode", Keyword.get(opts, :mode))
        |> put_present("order", Keyword.get(opts, :order))
        |> put_present("limit", Keyword.get(opts, :limit))
        |> put_present("raw", Keyword.get(opts, :raw))
        |> put_present("cursor", Keyword.get(opts, :cursor))

      {:ok, base(:query, request, opts)}
    end
  end

  defp context(argv) do
    with {:ok, opts} <- switches(argv, @context_switches, "context") do
      request =
        %{}
        |> put_present("trace_id", Keyword.get(opts, :trace_id))
        |> put_present("error_id", Keyword.get(opts, :error_id))
        |> put_present("service", Keyword.get(opts, :service))
        |> put_present("from", Keyword.get(opts, :from))
        |> put_present("to", Keyword.get(opts, :to))

      {:ok, base(:context, request, opts)}
    end
  end

  defp schema([]), do: {:error, "schema needs a source name: o11y-proxy schema <source>"}

  defp schema([name | rest]) do
    with {:ok, opts} <- switches(rest, @plain_switches, "schema") do
      {:ok, base(:schema, %{"source" => name}, opts)}
    end
  end

  defp plain(command, argv) do
    with {:ok, opts} <- switches(argv, @plain_switches, to_string(command)) do
      {:ok, base(command, %{}, opts)}
    end
  end

  # OptionParser in :strict mode reports unknown flags and bad values in `invalid` rather
  # than guessing, which is what turns a typo into a usage error instead of a query that
  # silently ignored half of what was asked for.
  defp switches(argv, definition, command) do
    case OptionParser.parse(argv, strict: definition) do
      {opts, [], []} ->
        {:ok, opts}

      # `invalid` is checked first because an unknown flag also strands its value in
      # `extra` — `--sources x` reports as both. "unknown option --sources" is the
      # diagnosis; "unexpected argument x" is a symptom of it.
      {_opts, _extra, [_ | _] = invalid} ->
        {:error, "#{command}: #{describe_invalid(invalid)}"}

      {_opts, extra, []} ->
        {:error, "#{command}: unexpected argument #{hd(extra)} — every option takes a --flag"}
    end
  end

  defp describe_invalid(invalid) do
    Enum.map_join(invalid, "; ", fn
      {flag, nil} -> "unknown option #{flag}"
      {flag, value} -> "#{flag} does not accept #{inspect(value)}"
    end)
  end

  defp required(opts, key, command) do
    case Keyword.get(opts, key) do
      nil -> {:error, "#{command} requires --#{String.replace(to_string(key), "_", "-")}"}
      value -> {:ok, value}
    end
  end

  defp filters(opts) do
    opts
    |> Keyword.get_values(:filter)
    |> Enum.reduce_while({:ok, []}, fn raw, {:ok, acc} ->
      case parse_filter(raw) do
        {:ok, filter} -> {:cont, {:ok, [filter | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  @doc """
  One `--filter` string → the canonical filter map `O11yProxy.Query.Filter.parse/1` takes.

  Operator tokens are matched at the earliest position in the string, longest token first,
  so `service!=cron` is `neq` rather than an `eq` on a field ending in `!`. A trailing `?`
  with no operator anywhere is `exists`.

  `in` deliberately has no compact form: comma-splitting a value would be ambiguous
  against values that legitimately contain commas. It stays reachable through `--raw` and
  the HTTP API.
  """
  @spec parse_filter(String.t()) :: {:ok, map()} | {:error, String.t()}
  def parse_filter(raw) when is_binary(raw) do
    case split_on_operator(raw) do
      {:ok, field, op, value} ->
        if field == "",
          do: {:error, ~s(--filter #{inspect(raw)} has no field before the operator)},
          else: {:ok, %{"field" => field, "op" => op, "value" => coerce(value)}}

      :exists ->
        case String.trim_trailing(raw, "?") do
          "" -> {:error, ~s(--filter "?" has no field name)}
          field -> {:ok, %{"field" => field, "op" => "exists", "value" => true}}
        end

      :none ->
        {:error,
         ~s(--filter #{inspect(raw)} has no operator — expected one of ) <>
           "field=v, field!=v, field>=v, field<=v, field~v, field=~v, or field?"}
    end
  end

  defp split_on_operator(raw) do
    last_index = max(String.length(raw) - 1, 0)

    case Enum.find_value(0..last_index, &operator_at(raw, &1)) do
      {field, op, value} -> {:ok, field, op, value}
      nil -> if String.ends_with?(raw, "?"), do: :exists, else: :none
    end
  end

  # The operator token starting at `index`, longest first, or nil if none starts there.
  defp operator_at(raw, index) do
    rest = String.slice(raw, index..-1//1)

    Enum.find_value(@filter_ops, fn {token, op} ->
      if String.starts_with?(rest, token) do
        # String.slice/2 returns "" past the end, never nil — no `|| ""` needed.
        value = String.slice(rest, String.length(token)..-1//1)
        {String.slice(raw, 0, index), op, value}
      end
    end)
  end

  # A shell has no types, but the backends do: `attributes.duration_ms>=1000` against a
  # numeric ClickHouse column has to send an Int64, not the string "1000" (see
  # `SQL.ch_type/1`). So numbers and booleans are coerced the way they'd arrive over JSON.
  # Wrapping a value in double quotes opts out, for the string column that holds "500".
  defp coerce(<<?", _::binary>> = value) do
    if String.ends_with?(value, ~s(")) and String.length(value) >= 2,
      do: String.slice(value, 1..-2//1),
      else: value
  end

  defp coerce("true"), do: true
  defp coerce("false"), do: false

  defp coerce(value) do
    with :error <- integer(value), :error <- float(value), do: value
  end

  defp integer(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> :error
    end
  end

  defp float(value) do
    case Float.parse(value) do
      {n, ""} -> n
      _ -> :error
    end
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp base(command, request, opts \\ []) do
    %{
      command: command,
      request: request,
      pretty: Keyword.get(opts, :pretty, false),
      quiet: Keyword.get(opts, :quiet, false)
    }
  end

  @doc "The version line. Read from the app spec — a release has no Mix to ask."
  @spec version_text() :: String.t()
  def version_text do
    vsn =
      case :application.get_key(:o11y_proxy, :vsn) do
        {:ok, vsn} -> List.to_string(vsn)
        :undefined -> "unknown"
      end

    "o11y-proxy #{vsn}"
  end

  @doc "The `--help` output."
  @spec help_text() :: String.t()
  def help_text do
    """
    o11y-proxy — one interface over logs, metrics, traces and errors.

    USAGE
      o11y-proxy                       run the HTTP server (same as `serve`)
      o11y-proxy serve                 run the HTTP server
      o11y-proxy query   [options]     run one query against one source
      o11y-proxy context [options]     correlate a trace, an error, or a service window
      o11y-proxy sources               list configured sources and their capabilities
      o11y-proxy schema <source>       canonical <-> native field map for one source
      o11y-proxy health                per-source reachability
      o11y-proxy --help | --version

    QUERY OPTIONS
      --source NAME        source to query                                    (required)
      --signal SIGNAL      logs | metrics | traces | errors                   (required)
      --from WHEN          e.g. now-1h, or an RFC3339 timestamp               (required)
      --to WHEN            e.g. now                                           (required)
      --mode MODE          summary | sample | full            (default: summary)
      --limit N            max records                        (default: from config)
      --order ORDER        asc | desc                         (default: desc)
      --filter EXPR        repeatable; see FILTERS below
      --raw QUERY          backend-native query, if the source allows it
      --cursor TOKEN       continue from a previous response's meta.cursor

    CONTEXT OPTIONS  (give exactly one of these three forms)
      --trace-id ID
      --error-id ID
      --service NAME --from WHEN --to WHEN

    OUTPUT
      --pretty             indent the JSON for reading; the default is compact, for jq
      --quiet              suppress the notes this prints to stderr

      Results go to stdout as JSON; notes and errors go to stderr, so `| jq` stays clean.
      Exit 0 when a response was produced — including a partial one with entries in
      `errors[]`, matching the HTTP 200 semantics. Exit 1 for usage, config, or
      connection failures.

    FILTERS
      --filter severity=error                      eq
      --filter service!=cron                       neq
      --filter attributes.duration_ms>=1000        gte
      --filter attributes.duration_ms<=50          lte
      --filter body~timeout                        contains
      --filter 'body=~^GET'                        regex
      --filter trace_id?                           exists

      Values that look like numbers or booleans are sent as numbers and booleans, since
      that is what the backends' columns expect. Wrap a value in double quotes to keep it
      a string: --filter 'status="500"'.

      The `in` operator has no compact form — comma-splitting would be ambiguous against
      values that legitimately contain commas. Use --raw or the HTTP API for it.

    CONFIGURATION
      Reads ./o11y.yaml, then ~/.config/o11y-proxy/config.yaml. Override with
      O11Y_PROXY_CONFIG=/path/to/config.yaml.
    """
  end
end
