defmodule O11yProxy.Backends.VictoriaMetrics do
  @moduledoc """
  Metrics adapter over VictoriaMetrics' Prometheus-compatible HTTP API. Built second, as
  "the real test of pluggability" since it's not SQL, unlike
  ClickHouse. If this needed changes to `O11yProxy.Backend` itself, the abstraction was
  overfit to SQL; it didn't.

  MetricsQL is a PromQL superset, so `raw` accepts exactly what an agent would already
  write — expect it to be reached for more than the structured path (`03-adapters.md`).
  `base_path` exists so cluster-mode tenant routing
  (`/select/<accountID>/prometheus/api/v1/...`) is a config value, not an assumption.

  `auth: bearer_file` is for a VictoriaMetrics behind an auth proxy, such as vmauth, that
  takes short-lived tokens from a broker. The token is reread from `token_file` on every
  request (`O11yProxy.Backends.TokenFile`), so whatever refreshes the file is all the
  rotation there is. The token carries the proxy's own identity: the backend enforces the
  scope it grants the proxy as a whole, and each caller's narrower policy is still
  enforced here, before the query is compiled.
  """

  @behaviour O11yProxy.Backend

  alias O11yProxy.Backends.TokenFile
  alias O11yProxy.Backends.VictoriaMetrics.PromQL

  require Logger

  @operators [:eq, :neq, :regex, :in]

  @impl true
  def config_schema do
    [
      url: [type: :string, required: true, doc: "e.g. \"http://localhost:8428\""],
      base_path: [
        type: :string,
        default: "",
        doc: "e.g. \"/select/0/prometheus\" for cluster-mode tenant routing"
      ],
      auth: [type: {:in, ["none", "basic", "bearer", "bearer_file"]}, default: "none"],
      username: [type: :string, default: ""],
      password: [type: :string, default: ""],
      token: [type: :string, default: ""],
      token_file: [
        type: :string,
        default: "",
        doc: "for auth: bearer_file, the file holding the token, reread on every request"
      ],
      allow_raw: [type: :boolean, default: false],
      timeout_ms: [type: :pos_integer, default: 30_000],
      summary_points: [type: :pos_integer, default: 50],
      full_points: [type: :pos_integer, default: 500]
    ]
  end

  @impl true
  def init(%{auth: "bearer_file", token_file: ""}),
    do: {:error, "auth: bearer_file needs token_file, the path of the file holding the token"}

  # A credential set for another mode would be silently ignored, and the one that is used
  # instead may be stale; refusing says which one the operator meant to drop.
  def init(%{auth: "bearer_file", token: token}) when token != "",
    do: {:error, "auth: bearer_file reads token_file; remove token, which would be ignored"}

  def init(%{auth: auth, token_file: path}) when auth != "bearer_file" and path != "",
    do: {:error, "token_file is only read with auth: bearer_file, not auth: #{auth}"}

  def init(config) do
    warn_if_unreadable(config)

    {:ok,
     %{
       url: String.trim_trailing(config.url, "/") <> config.base_path,
       auth: build_auth(config),
       # Tests point this at Req.Test; nothing in config sets it.
       req_options: Application.get_env(:o11y_proxy, :victoriametrics_req_options, []),
       allow_raw: config.allow_raw,
       timeout_ms: config.timeout_ms,
       summary_points: config.summary_points,
       full_points: config.full_points
     }}
  end

  # Not a boot failure: whatever writes the file may start after the proxy does, and the
  # source recovers by itself once it has. But a typo in the path looks the same, and
  # would otherwise show only as failing queries.
  defp warn_if_unreadable(%{auth: "bearer_file", token_file: path}) do
    with {:error, {_kind, reason}} <- TokenFile.read(path) do
      Logger.warning("victoriametrics token_file #{path}: #{reason}; queries fail until it is")
    end
  end

  defp warn_if_unreadable(_config), do: :ok

  defp build_auth(%{auth: "basic", username: u, password: p}), do: {:basic, "#{u}:#{p}"}
  defp build_auth(%{auth: "bearer", token: t}), do: {:bearer, t}
  defp build_auth(%{auth: "bearer_file", token_file: path}), do: {:bearer_file, path}
  defp build_auth(_), do: nil

  @impl true
  def capabilities(state) do
    %{
      signals: [:metrics],
      operators: @operators,
      modes: [:summary, :full],
      raw: state.allow_raw,
      max_window_ms: :infinity
    }
  end

  @impl true
  # The token is read once for the whole call, so its many requests share one credential
  # even if the file is rotated partway through.
  def schema(state) do
    with {:ok, state} <- with_token(state),
         {:ok, %{"data" => label_names}} <- get_json(state, "/api/v1/labels", %{}) do
      # Genuinely cheap, but still bounded — a VM instance can have hundreds of label
      # names, and we're not fetching one distinct-values call per.
      fields =
        label_names
        |> Enum.reject(&(&1 == "__name__"))
        |> Enum.take(20)
        |> Enum.map(fn label ->
          %{
            canonical: "labels.#{label}",
            native: label,
            type: "label",
            filterable: true,
            cardinality: "unknown",
            sample_values: label_values(state, label)
          }
        end)

      {:ok, %{name: "victoriametrics", fields: fields}}
    end
  end

  defp label_values(state, label) do
    case get_json(state, "/api/v1/label/#{URI.encode(label)}/values", %{}) do
      {:ok, %{"data" => values}} -> Enum.take(values, 20)
      {:error, _} -> []
    end
  end

  @impl true
  def compile(state, query) do
    with :ok <- check_cursor(query) do
      if query.raw do
        compile_raw(state, query)
      else
        compile_structured(state, query)
      end
    end
  end

  # Time-series `query_range` results aren't row-paginated the way ClickHouse/Sentry are
  # — an honest capability gap, not a bug.
  # Rejecting explicitly beats silently ignoring a cursor the caller expected to work.
  defp check_cursor(%{cursor: nil}), do: :ok

  defp check_cursor(%{cursor: cursor}) do
    {:error,
     {:invalid_cursor, "cursor #{inspect(cursor)} given but metrics don't support pagination"}}
  end

  defp compile_raw(state, query) do
    if state.allow_raw do
      {:ok,
       %{
         metricsql: query.raw,
         from: query.from,
         to: query.to,
         limit: query.limit,
         mode: query.mode
       }}
    else
      {:error, {:raw_not_allowed, "this source does not set allow_raw: true"}}
    end
  end

  defp compile_structured(_state, query) do
    with :ok <- check_operators(query.filters),
         {:ok, selector} <- PromQL.build_selector(query.filters) do
      {:ok,
       %{
         metricsql: selector,
         from: query.from,
         to: query.to,
         limit: query.limit,
         mode: query.mode
       }}
    end
  end

  defp check_operators(filters) do
    Enum.find_value(filters, :ok, fn f ->
      if f.op in @operators, do: nil, else: {:error, {:unsupported_operator, f.op}}
    end)
  end

  @impl true
  def execute(state, %{metricsql: metricsql, from: from, to: to, limit: limit, mode: mode}) do
    target = if mode == :summary, do: state.summary_points, else: state.full_points
    step = PromQL.step_seconds(from, to, target)

    params = %{
      "query" => metricsql,
      "start" => DateTime.to_unix(from),
      "end" => DateTime.to_unix(to),
      "step" => "#{step}s",
      "limit" => limit
    }

    with {:ok, %{"data" => %{"result" => result}}} <-
           get_json(state, "/api/v1/query_range", params) do
      series = Enum.map(result, &to_series/1)
      native = "GET #{state.url}/api/v1/query_range?#{URI.encode_query(params)}"
      {:ok, %{records: series, native: native, total: length(series)}}
    end
  end

  defp to_series(%{"metric" => metric, "values" => values}) do
    {name, labels} = Map.pop(metric, "__name__", "")

    points =
      Enum.map(values, fn [ts, value_str] ->
        {value, _} = Float.parse(value_str)
        [round(ts * 1000), value]
      end)

    %{name: name, labels: labels, points: points}
  end

  @impl true
  # Sends the credential too: behind an auth proxy, /health under base_path is routed like
  # any other path, and a token that cannot be read is worth reporting as unhealthy.
  def health(state) do
    with {:ok, opts} <- request_options(state, receive_timeout: state.timeout_ms) do
      health_status(Req.get(state.url <> "/health", opts))
    end
  end

  defp health_status(response) do
    case response do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, %{status: status}} ->
        {:error, {:unhealthy, status}}

      {:error, exception} ->
        {:error, {:victoriametrics_unreachable, Exception.message(exception)}}
    end
  end

  defp get_json(state, path, params) do
    with {:ok, opts} <- request_options(state, params: params, receive_timeout: state.timeout_ms) do
      json_result(Req.get(state.url <> path, opts))
    end
  end

  defp json_result(response) do
    case response do
      {:ok, %{status: 200, body: %{"status" => "success"} = body}} ->
        {:ok, body}

      {:ok, %{status: 200, body: %{"status" => "error", "error" => reason}}} ->
        {:error, {:victoriametrics_error, reason}}

      {:ok, %{status: status, body: body}} ->
        {:error, {:victoriametrics_error, "HTTP #{status}: #{inspect(body)}"}}

      {:error, exception} ->
        {:error, {:victoriametrics_unreachable, Exception.message(exception)}}
    end
  end

  # The request's own options go last, so nothing in req_options can replace the
  # credential or the params.
  defp request_options(state, opts) do
    with {:ok, state} <- with_token(state) do
      {:ok, Keyword.merge(state.req_options, maybe_put_auth(opts, state.auth))}
    end
  end

  # Swaps a token file for the token it holds now. A state that already holds a token
  # passes through, which is what lets one call read the file once.
  #
  # A token that cannot be read is the proxy's credential failing, not the backend, so it
  # is `:credential_unavailable` or `:credential_invalid` — which Sources keeps out of the
  # circuit breaker, so the reason reaches the caller instead of "breaker open".
  defp with_token(%{auth: {:bearer_file, path}} = state) do
    case TokenFile.read(path) do
      {:ok, token} -> {:ok, %{state | auth: {:bearer, token}}}
      {:error, {:unavailable, reason}} -> {:error, {:credential_unavailable, reason}}
      {:error, {:invalid, reason}} -> {:error, {:credential_invalid, reason}}
    end
  end

  defp with_token(state), do: {:ok, state}

  defp maybe_put_auth(opts, nil), do: opts
  defp maybe_put_auth(opts, auth), do: Keyword.put(opts, :auth, auth)
end
