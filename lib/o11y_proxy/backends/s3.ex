defmodule O11yProxy.Backends.S3 do
  @moduledoc """
  Logs and traces adapter over object storage, executed by an embedded DuckDB via ADBC.

  The other three adapters talk to a service that is already running and already indexed.
  This one talks to a bucket. That is the whole point: the logs you need during an incident
  are frequently the ones that aged out of the hot store, and a prefix full of gzipped
  NDJSON has no query interface at all until something puts SQL in front of it.

  Nothing here is S3-specific. DuckDB reads `s3://`, `gs://`, `r2://`, `az://`, `https://`
  and local paths through the same table functions, and `format` covers JSON, Parquet and
  CSV — so `backend: s3` serves a Cloudflare R2 bucket or a directory of Parquet files
  without a second adapter. The name follows the common case, not the limit.

  Guardrails, layered:

    * an IAM policy scoped to the prefix is the real boundary — configure it at AWS, this
      adapter cannot enforce it
    * the DuckDB session is locked down at init: `disabled_filesystems` blocks local file
      access for object-store sources, then `lock_configuration` makes every `SET` and
      `CREATE SECRET` after that point fail, so a raw query cannot undo either
    * every compiled query carries a bound on `hints.partition_key`, and — when the source
      declares `hints.hive_date_column` — a second bound on the Hive partition column,
      injected inside the scan CTE where it actually prunes files (see
      `O11yProxy.Backends.S3.SQL`)
    * the `raw` escape hatch is validated as a single `SELECT` against DuckDB's write verbs
      and gated on `allow_raw`
    * `memory_limit` and `threads` bound what a bad query can consume in-process — unlike
      the other adapters, this engine runs inside the proxy

  Cost is the design constraint the other adapters do not have. Object storage bills per
  GET and per byte scanned, so a query that fails to prune partitions is not slow, it is
  expensive. That is why the Hive bound is mandatory when configured and why it lives
  inside the scan rather than in the outer `WHERE`.
  """

  @behaviour O11yProxy.Backend

  alias Adbc.Connection
  alias Adbc.Database
  alias Adbc.Result
  alias O11yProxy.Backend
  alias O11yProxy.Backends.S3.SQL
  alias O11yProxy.Cursor
  alias O11yProxy.Query
  alias O11yProxy.Record

  @operators [:eq, :neq, :gte, :lte, :contains, :regex, :in, :exists]

  # Schemes that mean "object storage", and so need an S3-compatible secret and must not
  # be able to reach the local filesystem. Everything else (a local path, `file://`,
  # `https://`) skips secret creation.
  @object_store_schemes ~w(s3 gs gcs r2 az azure abfss)

  @impl true
  def config_schema do
    [
      uri: [
        type: :string,
        required: true,
        doc:
          "the object glob, e.g. \"s3://acme-logs/cw/**/*.gz\". Any DuckDB-readable scheme works"
      ],
      format: [type: {:in, ["json", "parquet", "csv"]}, default: "json"],
      region: [type: :string, default: ""],
      access_key_id: [
        type: :string,
        default: "",
        doc: "leave all three credential keys empty to use DuckDB's AWS credential chain"
      ],
      secret_access_key: [type: :string, default: ""],
      session_token: [type: :string, default: ""],
      endpoint: [type: :string, default: "", doc: "for MinIO/R2/Ceph, e.g. \"localhost:9000\""],
      url_style: [type: :string, default: "", doc: "\"vhost\" or \"path\""],
      use_ssl: [type: :boolean, default: true],
      hive_partitioning: [type: :boolean, default: true],
      read_options: [
        type: {:map, :string, :any},
        default: %{},
        doc:
          "extra kwargs spliced into read_json/read_parquet/read_csv, e.g. %{\"maximum_depth\" => 3}"
      ],
      transform: [
        type: :string,
        default: "",
        doc:
          "a SELECT over the raw scan, exposed as `scan`, producing the flat columns `mapping` names"
      ],
      mapping: [
        type: {:map, :string, :string},
        required: true,
        doc: "canonical field -> column of the transformed rows, e.g. %{\"timestamp\" => \"ts\"}"
      ],
      hints: [
        type: {:map, :string, :any},
        default: %{},
        doc:
          ~s[keys: "partition_key" (the row timestamp column, always bounded), ] <>
            ~s["hive_date_column" (the Hive partition column to prune on), ] <>
            ~s["low_cardinality" (a list of columns), ] <>
            ~s["attribute_access" (either "map" or "json")]
      ],
      allow_raw: [type: :boolean, default: false],
      memory_limit: [type: :string, default: "2GB"],
      threads: [type: :pos_integer, default: 4],
      extension_directory: [
        type: :string,
        default: "",
        doc: "where httpfs/json are installed; set it to a pre-populated dir for airgapped hosts"
      ],
      timeout_ms: [type: :pos_integer, default: 60_000]
    ]
  end

  @impl true
  def init(config) do
    with {:ok, conn} <- start_duckdb() do
      state = build_state(conn, config)

      case apply_session_guardrails(conn, config, state) do
        :ok -> {:ok, state}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp start_duckdb do
    with {:ok, db} <- Database.start_link(driver: :duckdb) do
      Connection.start_link(database: db)
    end
  rescue
    # Narrow on purpose: `adbc`'s NIF stubs call `:erlang.nif_error(:not_loaded)` when the
    # shared library could not be dlopen'd, and that is a *known, documented* state rather
    # than a bug to hand back as a stacktrace. The single-file binaries are built on a
    # musl-linked ERTS while adbc's precompiled NIF is glibc-linked, so DuckDB cannot load
    # inside them; the OTP release tarball and a source install are fine. Anything else
    # re-raises.
    error in ErlangError ->
      if error.original == :not_loaded do
        {:error,
         {:duckdb_unavailable,
          "DuckDB's native library could not be loaded. The `s3` backend does not work " <>
            "in the single-file binary — use the OTP release tarball or run from source. " <>
            "See README.md, \"Building the binaries\"."}}
      else
        reraise(error, __STACKTRACE__)
      end
  end

  defp build_state(conn, config) do
    mapping = config.mapping
    hints = config.hints

    %{
      conn: conn,
      uri: config.uri,
      format: config.format,
      hive_partitioning: config.hive_partitioning,
      read_options: config.read_options,
      transform: config.transform,
      mapping: mapping,
      allow_raw: config.allow_raw,
      timeout_ms: config.timeout_ms,
      partition_key: Map.get(hints, "partition_key") || Map.fetch!(mapping, "timestamp"),
      hive_date_column: Map.get(hints, "hive_date_column"),
      low_cardinality: Map.get(hints, "low_cardinality", []),
      attribute_access: attribute_access(hints)
    }
  end

  defp attribute_access(hints) do
    if Map.get(hints, "attribute_access") == "json", do: :json, else: :map
  end

  # Runs once, on the connection this source owns for its lifetime. It is network I/O in
  # `init/1`, which the behaviour discourages — the same deviation `ClickHouse.init/1`
  # makes by starting a pool, and for the same reason: the alternative is re-running an
  # extension load on every query, and a broken bucket should fail boot loudly via
  # `{:backend_init_failed, ...}` rather than at 3am.
  #
  # Order is load-bearing. `lock_configuration` goes last, because after it nothing else
  # in this list would be allowed to run.
  defp apply_session_guardrails(conn, config, state) do
    statements =
      extension_directory_statement(config) ++
        extension_statements(config, state) ++
        [
          # Not cosmetic. A `TIMESTAMP WITH TIME ZONE` column — which is what
          # `to_timestamp()` produces, and what most transforms end up with — is rendered
          # by DuckDB in the *session* timezone. ADBC hands those back as naive values and
          # `Record.format_timestamp/1` stamps them `Z`, so on a host whose clock is not
          # UTC every record would carry a correct-looking, wrong timestamp.
          "SET TimeZone = 'UTC'",
          "SET memory_limit = #{SQL.quote_literal(config.memory_limit)}",
          "SET threads = #{config.threads}"
        ] ++
        filesystem_statements(state) ++
        secret_statements(config, state) ++
        ["SET lock_configuration = true"]

    Enum.reduce_while(statements, :ok, fn sql, :ok ->
      case Connection.query(conn, sql, []) do
        {:ok, _} -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, session_error(sql, error)}}
      end
    end)
  end

  defp extension_directory_statement(%{extension_directory: ""}), do: []

  defp extension_directory_statement(%{extension_directory: dir}),
    do: ["SET extension_directory = #{SQL.quote_literal(dir)}"]

  # Only what this source actually needs. `parquet` and the CSV reader are statically
  # linked into libduckdb; `httpfs` (the s3:// scheme), `aws` (the credential chain) and
  # `json` (NDJSON) are repository extensions fetched from extensions.duckdb.org on first
  # install and cached under `extension_directory`.
  #
  # DuckDB would autoload all three on demand, so the explicit INSTALL/LOAD buys two
  # things: a source pointing at local Parquet needs no network at all, and a host that
  # cannot reach the extension repository fails at boot with a statement to search for
  # rather than mid-incident inside a query.
  defp extension_statements(config, state) do
    remote = object_store?(state.uri) or http?(state.uri)

    []
    |> maybe_extension(remote, "httpfs")
    |> maybe_extension(remote and config.access_key_id == "", "aws")
    |> maybe_extension(config.format == "json", "json")
  end

  defp maybe_extension(statements, false, _extension), do: statements

  defp maybe_extension(statements, true, extension),
    do: statements ++ ["INSTALL #{extension}", "LOAD #{extension}"]

  # A source reading a bucket has no business reading the proxy's own disk, and this is
  # what makes `allow_raw: true` defensible — a raw query cannot `read_csv('/etc/passwd')`.
  # A source pointing at a local directory obviously needs the local filesystem, so it
  # keeps it and documents `allow_raw` as the riskier choice.
  defp filesystem_statements(state) do
    if object_store?(state.uri),
      do: ["SET disabled_filesystems = 'LocalFileSystem'"],
      else: []
  end

  defp secret_statements(config, state) do
    if object_store?(state.uri), do: [create_secret(config)], else: []
  end

  # Secret values are config, never request input, so they are spliced as quoted literals
  # — DDL takes no bound parameters. This statement is deliberately never part of what
  # `execute/2` returns as `:native`, so credentials cannot reach `meta.native_queries`.
  defp create_secret(%{access_key_id: ""} = config) do
    "CREATE OR REPLACE SECRET o11y_proxy (TYPE s3, PROVIDER credential_chain" <>
      secret_option("REGION", config.region) <>
      secret_option("ENDPOINT", config.endpoint) <>
      secret_option("URL_STYLE", config.url_style) <>
      ", USE_SSL #{config.use_ssl})"
  end

  defp create_secret(config) do
    "CREATE OR REPLACE SECRET o11y_proxy (TYPE s3" <>
      secret_option("KEY_ID", config.access_key_id) <>
      secret_option("SECRET", config.secret_access_key) <>
      secret_option("SESSION_TOKEN", config.session_token) <>
      secret_option("REGION", config.region) <>
      secret_option("ENDPOINT", config.endpoint) <>
      secret_option("URL_STYLE", config.url_style) <>
      ", USE_SSL #{config.use_ssl})"
  end

  defp secret_option(_key, ""), do: ""
  defp secret_option(key, value), do: ", #{key} #{SQL.quote_literal(value)}"

  defp object_store?(uri), do: scheme(uri) in @object_store_schemes

  defp http?(uri), do: scheme(uri) in ~w(http https)

  defp scheme(uri) do
    case URI.parse(uri) do
      %URI{scheme: scheme} when is_binary(scheme) -> scheme
      _ -> nil
    end
  end

  # The message is scrubbed of the statement's own text for the secret case, so a
  # misconfigured key never lands in a log line or a boot error.
  defp session_error(sql, error) do
    statement =
      if String.starts_with?(sql, "CREATE OR REPLACE SECRET"), do: "CREATE SECRET", else: sql

    {:s3_unreachable, "#{statement} failed: #{Exception.message(error)}"}
  end

  @impl true
  def capabilities(state) do
    %{
      signals: [:logs, :traces],
      operators: @operators,
      modes: [:summary, :sample, :full],
      raw: state.allow_raw,
      max_window_ms: :infinity
    }
  end

  @impl true
  def schema(state) do
    with {:ok, ctes, params} <- ctes_with_params(state, introspection_query()) do
      case run(state, "DESCRIBE WITH #{ctes} SELECT * FROM src", params) do
        {:ok, %{"column_name" => names, "column_type" => types}} ->
          native_types = names |> Enum.zip(types) |> Map.new()
          {:ok, %{name: state.uri, fields: fields(state, native_types)}}

        {:ok, _other} ->
          {:error, {:duckdb_error, "DESCRIBE returned an unexpected shape"}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # `schema/1` has no request to take a window from, but the scan CTE still builds its
  # Hive bound from one. A day is enough to land on a partition that exists without
  # widening the scan to the whole bucket.
  defp introspection_query do
    now = DateTime.utc_now()
    %Query{signal: :logs, from: DateTime.add(now, -86_400, :second), to: now}
  end

  defp fields(state, native_types) do
    Backend.schema_fields(
      state.mapping,
      native_types,
      state.low_cardinality,
      &distinct_values(state, &1)
    )
  end

  # Sample values are a nicety on top of `schema/1`, so every failure here degrades to an
  # empty list rather than failing the whole schema call.
  defp distinct_values(state, native) do
    case ctes_with_params(state, introspection_query()) do
      {:ok, ctes, params} ->
        sql = "WITH #{ctes} SELECT DISTINCT #{SQL.quote_ident(native)} AS v FROM src LIMIT 20"

        case run(state, sql, params) do
          {:ok, %{"v" => values}} -> values
          _ -> []
        end

      _ ->
        []
    end
  end

  @impl true
  def compile(state, query) do
    if query.raw, do: compile_raw(state, query), else: compile_structured(state, query)
  end

  defp compile_raw(state, query) do
    if state.allow_raw do
      with :ok <- SQL.validate_single_select(query.raw) do
        {:ok, %{sql: query.raw, params: [], kind: :raw, limit: query.limit, paginate: false}}
      end
    else
      {:error, {:raw_not_allowed, "this source does not set allow_raw: true"}}
    end
  end

  defp compile_structured(state, query) do
    with :ok <- check_operators(query.filters),
         {:ok, ctes, scan_params} <- ctes_with_params(state, query),
         {:ok, {filter_sql, filter_params}} <-
           SQL.build_where(state.mapping, query.filters, state.attribute_access),
         {:ok, {where_sql, where_params}} <- add_bounds(state, query, filter_sql, filter_params) do
      {sql, kind} =
        case query.mode do
          :summary -> {SQL.summary_sql(state, ctes, where_sql, query), :summary}
          :sample -> {SQL.sample_sql(state, ctes, where_sql, query), :records}
          :full -> {SQL.full_sql(state, ctes, where_sql, query), :records}
        end

      {:ok,
       %{
         sql: sql,
         params: scan_params ++ where_params,
         kind: kind,
         limit: query.limit,
         paginate: query.mode == :full
       }}
    end
  end

  defp ctes_with_params(state, query) do
    {scan, scan_params} = SQL.scan_cte(state, query)

    with {:ok, src} <- SQL.src_cte(state) do
      {:ok, "#{scan}, #{src}", scan_params}
    end
  end

  # The row-level time bound is unconditional — every query, every mode, the same
  # non-negotiable guardrail ClickHouse applies. The Hive bound inside the scan CTE is a
  # *file* filter and does not replace it: partitions are hour-granular at best, and a
  # request for the last five minutes must not return the whole hour.
  #
  # Cursor bound only applies to `mode: full`; a cursor supplied for :summary/:sample is
  # an explicit error, not silently ignored — neither mode has a stable per-row key to
  # page from.
  defp add_bounds(state, query, filter_sql, filter_params) do
    partition = SQL.quote_ident(state.partition_key)
    time_bound = "#{partition} BETWEEN ? AND ?"
    bound_params = [DateTime.to_naive(query.from), DateTime.to_naive(query.to)]

    with {:ok, {cursor_clause, cursor_params}} <- cursor_bound_for_mode(state, query) do
      where_sql =
        [time_bound, filter_sql, cursor_clause]
        |> Enum.reject(&(&1 == ""))
        |> Enum.join(" AND ")

      {:ok, {where_sql, bound_params ++ filter_params ++ cursor_params}}
    end
  end

  defp cursor_bound_for_mode(state, %{mode: :full, cursor: cursor, order: order}) do
    SQL.cursor_bound(state.mapping, cursor, order, state.attribute_access)
  end

  defp cursor_bound_for_mode(_state, %{cursor: nil}), do: {:ok, {"", []}}

  defp cursor_bound_for_mode(_state, %{cursor: cursor}) do
    {:error,
     {:invalid_cursor, "cursor #{inspect(cursor)} given but only mode: full supports pagination"}}
  end

  defp check_operators(filters) do
    Enum.find_value(filters, :ok, fn f ->
      if f.op in @operators, do: nil, else: {:error, {:unsupported_operator, f.op}}
    end)
  end

  @impl true
  def execute(state, %{sql: sql, params: params, kind: kind} = native) do
    case run(state, sql, params) do
      {:ok, columns} ->
        records = to_output(kind, columns)
        result = %{records: records, native: sql, total: length(records)}
        {:ok, maybe_put_cursor(result, native, records)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A full page (exactly `limit` rows) means there might be more — hand back a cursor
  # keyed on the last row's timestamp. A short page means we've reached the end.
  defp maybe_put_cursor(result, %{paginate: true, limit: limit}, records)
       when length(records) == limit and records != [] do
    Map.put(result, :cursor, Cursor.encode("s3", %{"ts" => List.last(records).timestamp}))
  end

  defp maybe_put_cursor(result, _native, _records), do: result

  @impl true
  def health(state) do
    case run(state, "SELECT 1 AS ok", []) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp run(state, sql, params) do
    case Connection.query(state.conn, sql, params) do
      {:ok, result} -> {:ok, Result.to_map(result)}
      {:error, error} -> {:error, classify(Exception.message(error))}
    end
  end

  # DuckDB reports a missing bucket, a bad key and an expired token as ordinary IO errors,
  # so the string is all there is to go on. Getting this right matters beyond tidiness:
  # `unreachable` is the code `O11yProxy.ResponseError` maps to a retry hint, and a
  # credentials problem that reads as `internal` sends someone reading source instead of
  # checking their role.
  @unreachable_markers [
    "HTTP Error",
    "IO Error",
    "Connection Error",
    "No files found",
    "403",
    "404",
    "credential",
    "Credential"
  ]

  defp classify(message) do
    if Enum.any?(@unreachable_markers, &String.contains?(message, &1)),
      do: {:s3_unreachable, message},
      else: {:duckdb_error, message}
  end

  defp to_output(:summary, columns) do
    zip(columns, ~w(bucket severity service count))
    |> Enum.map(fn [bucket, severity, service, count] ->
      %{
        bucket: Record.format_timestamp(bucket),
        severity: Record.normalize_severity(severity),
        service: to_string(service),
        count: count
      }
    end)
  end

  defp to_output(:records, columns) do
    zip(columns, ~w(timestamp severity body service trace_id span_id attributes))
    |> Enum.map(fn [ts, severity, body, service, trace_id, span_id, attributes] ->
      %Record{
        timestamp: Record.format_timestamp(ts),
        severity: Record.normalize_severity(severity),
        body: to_string(body),
        service: to_string(service),
        trace_id: nil_if_empty(trace_id),
        span_id: nil_if_empty(span_id),
        attributes: attributes_map(attributes),
        source: ""
      }
    end)
  end

  defp to_output(:raw, columns) do
    names = Map.keys(columns)

    columns
    |> zip(names)
    |> Enum.map(&Map.new(Enum.zip(names, &1)))
  end

  # ADBC hands back Arrow columns, so a result is column-oriented: %{"body" => [...], ...}.
  # Transpose into rows in the projection's own order rather than the map's.
  defp zip(columns, names) do
    names
    |> Enum.map(&Map.get(columns, &1, []))
    |> Enum.zip_with(& &1)
  end

  defp attributes_map(attributes) when is_map(attributes), do: attributes
  defp attributes_map(attributes) when is_list(attributes), do: Map.new(attributes)
  defp attributes_map(_), do: %{}

  defp nil_if_empty(""), do: nil
  defp nil_if_empty(other), do: other
end
