defmodule O11yProxy.Test.FakeErrorsBackend do
  @moduledoc """
  An `:errors`-signal fixture implementing the optional `fetch_by_id/2` callback, so
  `POST /v1/context {"error_id": ...}` is testable without a live Sentry — same reason
  `O11yProxy.Test.FakeBackend` exists (Phase 1 built the contract suite before any real
  adapter). Sentry is the only real backend that implements `fetch_by_id/2`.

  `known_id` is the one ID it "has"; anything else is `{:error, :not_found}`, so the
  "no matching error" path (`error: null`, no `errors` entry) is exercised too.
  """

  @behaviour O11yProxy.Backend

  alias O11yProxy.Record

  @impl true
  def config_schema do
    [
      known_id: [type: :string, default: "ERR-1"],
      trace_id: [type: :string, default: "abc123"],
      fail: [type: :boolean, default: false]
    ]
  end

  @impl true
  def init(config) do
    {:ok,
     %{
       known_id: Map.get(config, :known_id, "ERR-1"),
       trace_id: Map.get(config, :trace_id, "abc123"),
       fail: Map.get(config, :fail, false)
     }}
  end

  @impl true
  def capabilities(_state) do
    %{
      signals: [:errors],
      operators: [:eq],
      modes: [:full],
      raw: false,
      max_window_ms: :infinity
    }
  end

  @impl true
  def compile(_state, query) do
    {:ok, %{filters: query.filters, from: query.from, to: query.to, limit: query.limit}}
  end

  @impl true
  def execute(%{fail: true}, _native),
    do: {:error, {:fake_unreachable, "fake errors backend set to fail"}}

  def execute(state, _native) do
    {:ok, %{records: [record(state)], native: "FAKE errors lookup", total: 1}}
  end

  @impl true
  def fetch_by_id(%{fail: true}, _id),
    do: {:error, {:fake_unreachable, "fake errors backend set to fail"}}

  def fetch_by_id(%{known_id: known_id} = state, id) when id == known_id do
    {:ok, record(state)}
  end

  def fetch_by_id(_state, _id), do: {:error, :not_found}

  @impl true
  def health(_state), do: :ok

  defp record(state) do
    %Record{
      timestamp: DateTime.to_iso8601(DateTime.utc_now()),
      severity: :error,
      body: "fake issue: everything is on fire",
      service: "fake-service",
      trace_id: state.trace_id,
      span_id: nil,
      attributes: %{"issue_id" => state.known_id, "authorization" => "Bearer super-secret"},
      source: ""
    }
  end
end
