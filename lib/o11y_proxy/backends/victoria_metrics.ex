defmodule O11yProxy.Backends.VictoriaMetrics do
  @moduledoc """
  Metrics adapter over VictoriaMetrics' Prometheus-compatible HTTP API. Built second per
  `.plans/03-adapters.md` — "the real test of pluggability" since it's not SQL, unlike
  ClickHouse. If this needed changes to `O11yProxy.Backend` itself, the abstraction was
  overfit to SQL; it didn't.

  MetricsQL is a PromQL superset, so `raw` accepts exactly what an agent would already
  write — expect it to be reached for more than the structured path (`03-adapters.md`).
  `base_path` exists so cluster-mode tenant routing
  (`/select/<accountID>/prometheus/api/v1/...`) is a config value, not an assumption.
  """

  @behaviour O11yProxy.Backend

  alias O11yProxy.Backends.VictoriaMetrics.PromQL

  @operators [:eq, :neq, :regex]

  @impl true
  def config_schema do
    [
      url: [type: :string, required: true, doc: "e.g. \"http://localhost:8428\""],
      base_path: [
        type: :string,
        default: "",
        doc: "e.g. \"/select/0/prometheus\" for cluster-mode tenant routing"
      ],
      auth: [type: {:in, ["none", "basic", "bearer"]}, default: "none"],
      username: [type: :string, default: ""],
      password: [type: :string, default: ""],
      token: [type: :string, default: ""],
      allow_raw: [type: :boolean, default: false],
      timeout_ms: [type: :pos_integer, default: 30_000],
      summary_points: [type: :pos_integer, default: 50],
      full_points: [type: :pos_integer, default: 500]
    ]
  end

  @impl true
  def init(config) do
    {:ok,
     %{
       url: String.trim_trailing(config.url, "/") <> config.base_path,
       auth: build_auth(config),
       allow_raw: config.allow_raw,
       timeout_ms: config.timeout_ms,
       summary_points: config.summary_points,
       full_points: config.full_points
     }}
  end

  defp build_auth(%{auth: "basic", username: u, password: p}), do: {:basic, "#{u}:#{p}"}
  defp build_auth(%{auth: "bearer", token: t}), do: {:bearer, t}
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
  def schema(state) do
    with {:ok, %{"data" => label_names}} <- get_json(state, "/api/v1/labels", %{}) do
      # Genuinely cheap per .plans/03-adapters.md, but still bounded — a VM instance can
      # have hundreds of label names, and we're not fetching one distinct-values call per.
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
    if query.raw do
      compile_raw(state, query)
    else
      compile_structured(state, query)
    end
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
  def health(state) do
    case Req.get(state.url <> "/health", receive_timeout: state.timeout_ms) do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, %{status: status}} ->
        {:error, {:unhealthy, status}}

      {:error, exception} ->
        {:error, {:victoriametrics_unreachable, Exception.message(exception)}}
    end
  end

  defp get_json(state, path, params) do
    opts =
      [params: params, receive_timeout: state.timeout_ms]
      |> maybe_put_auth(state.auth)

    case Req.get(state.url <> path, opts) do
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

  defp maybe_put_auth(opts, nil), do: opts
  defp maybe_put_auth(opts, auth), do: Keyword.put(opts, :auth, auth)
end
