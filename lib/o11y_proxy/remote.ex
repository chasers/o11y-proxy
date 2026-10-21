defmodule O11yProxy.Remote do
  @moduledoc """
  The one entry point every transport goes through: a string-keyed request in, an
  already-shaped response map out.

  This is the single stable façade the CLI `:erpc`s
  into a running daemon. Keeping it to *one* function is what contains version skew —
  a newer CLI talking to an older daemon depends on this contract and nothing else,
  never on the shape of an internal function.

  It earns its place before any of that, though, because it is also what stops the CLI
  and the HTTP router being two implementations of the same dispatch. The router is now
  a thin shell that calls `handle/1` and maps the result onto a status code; the CLI
  calls `handle/1` and maps it onto an exit code. Neither decides what a query response
  contains.

  The `{:ok, _}` / `{:error, _}` split is the transport-neutral form of "did we produce a
  response": `{:ok, body}` is HTTP 200 and CLI exit 0 — *including* a partial result whose
  `errors` list is non-empty, which is the normal path for a fan-out where one source is
  down. `{:error, body}` is a request that could not be
  served at all: a malformed query, an unknown source. `body` is JSON-encodable either way.

  ## Reaching a running daemon

  The CLI prefers a daemon when one is up, because it already holds warm connection pools
  and live circuit-breaker state. The hop is Erlang distribution rather than HTTP, so the
  two processes exchange native terms and only the CLI ever encodes JSON.

  `node_name/1` derives the daemon's node name from the *config*, so both sides compute
  the same one with no handshake file to write, stale-lock, or clean up — and two daemons
  on different ports don't collide.

  `start_distribution/1` binds distribution to loopback *before* `net_kernel` starts.
  `:erpc` is remote code execution; the distribution port must never be reachable off-box.
  With that in place the cookie is the remaining barrier, and both sides get it
  automatically by being the same binary — which also means a Burrito binary and a tarball
  release do not share one, and simply fall back to in-process rather than failing.
  """

  alias O11yProxy.{Caller, Context, Policy, Query, Response, ResponseError, Sources}

  @protocol_version 1
  @public_health_max_age_ms 5_000

  @doc """
  The version of `handle/1`'s contract.

  Deliberately a protocol integer rather than the app version: it is bumped only when the
  request or response shape here actually changes, so a 0.1.0 CLI keeps using a 0.1.4
  daemon instead of falling back to a cold in-process run on every patch release.
  """
  @spec protocol_version() :: pos_integer()
  def protocol_version, do: @protocol_version

  @doc """
  The daemon's node name for a given config.

  Derived from the port so that both sides compute the same name without exchanging
  anything, and so two daemons with different configs never collide on one name.
  """
  @spec node_name(O11yProxy.Config.t()) :: node()
  def node_name(%O11yProxy.Config{server: %{port: port}}),
    do: :"o11y_proxy_#{port}@127.0.0.1"

  @doc """
  Starts `net_kernel` under `name`, bound to loopback.

  The `inet_dist_use_interface` setting has to be in place *before* `net_kernel` starts —
  it is read when the listen socket is opened — which is why this is one function both
  sides call rather than two similar blocks that could drift apart. Without it, the
  distribution port would accept connections from off-box, and `:erpc` is remote code
  execution.

  Already-started is success: a caller that finds distribution running (a tarball release
  started with `-name`, say) should use it rather than fail.
  """
  @spec start_distribution(node()) :: :ok | {:error, term()}
  def start_distribution(name) do
    Application.put_env(:kernel, :inet_dist_use_interface, {127, 0, 0, 1})

    case :net_kernel.start(name, %{name_domain: :longnames}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Runs one command as the local, unrestricted caller. This is what the CLI calls, in
  process or over `:erpc` — its arity is part of the cross-version contract, which is
  why the caller-aware form is a separate `handle/2` rather than a new argument here.
  """
  @spec handle(map()) :: {:ok, map()} | {:error, map()}
  def handle(request), do: handle(request, Caller.local())

  @doc """
  Runs one command for `caller`. `request` is the same string-keyed map the corresponding
  HTTP endpoint receives (straight from `Jason.decode!/1`, or built by
  `O11yProxy.CLI.Args`). The caller's policy is enforced in `O11yProxy.Sources`, not
  here, so this stays dispatch only.
  """
  @spec handle(map(), Caller.t()) :: {:ok, map()} | {:error, map()}
  def handle(%{"command" => "query", "request" => request}, caller) do
    case Query.parse(request, default_limit: default_limit(caller)) do
      {:ok, query} -> run_query(query, caller)
      {:error, reason} -> invalid_query(inspect(reason))
    end
  end

  def handle(%{"command" => "context", "request" => request}, caller) do
    case Context.resolve(request, caller) do
      {:ok, bundle} ->
        {:ok, Response.context_bundle(bundle)}

      {:error, :ambiguous_request} ->
        invalid_query("give exactly one of trace_id, error_id, or {from, to, service}")

      {:error, :empty_request} ->
        invalid_query("one of trace_id, error_id, or {from, to, service} is required")

      {:error, reason} ->
        invalid_query(inspect(reason))
    end
  end

  def handle(%{"command" => "sources"}, caller), do: {:ok, %{sources: Sources.list(caller)}}

  # `"public"` is set by the HTTP router, never by a caller: it marks the open `/healthz`
  # route under auth, which gets a short-lived cached, status-only answer.
  def handle(%{"command" => "health", "request" => %{"public" => true}}, _caller),
    do: {:ok, Sources.healthz(max_age_ms: @public_health_max_age_ms, status_only: true)}

  def handle(%{"command" => "health"}, _caller), do: {:ok, Sources.healthz()}

  def handle(%{"command" => "schema", "request" => %{"source" => name}}, caller) do
    case Sources.schema(name, caller) do
      {:ok, schema} ->
        {:ok, schema}

      {:error, {:forbidden, message}} ->
        forbidden(message)

      {:error, :not_found} ->
        {:error, %{error: "not_found", message: "no such source: #{name}"}}

      {:error, :not_supported} ->
        {:error,
         %{
           error: "not_supported",
           message: "source #{name} does not support schema discovery"
         }}

      {:error, reason} ->
        {:error, %{error: "schema_error", message: inspect(reason)}}
    end
  end

  def handle(other, _caller) do
    {:error, %{error: "invalid_query", message: "unrecognized request: #{inspect(other)}"}}
  end

  # Single-source only. Fan-out across several sources at once — merging, ranking and
  # budget-shaping one combined result — is not built. `/v1/context` is the way to reach
  # several sources in one call today: it correlates rather than merges.
  defp run_query(%{sources: [name]} = query, caller) do
    started = System.monotonic_time(:millisecond)

    case Sources.run_query(name, query, caller) do
      {:ok, result} ->
        elapsed = System.monotonic_time(:millisecond) - started
        {:ok, Response.query_envelope(name, result, query.mode, elapsed, [])}

      {:error, :not_found} ->
        {:error, %{error: "not_found", message: "no such source: #{name}"}}

      # A policy refusal is a request this caller may not make, not a source that broke,
      # so it is refused outright rather than reported as a partial result.
      {:error, {:forbidden, message}} ->
        forbidden(message)

      # A backend that failed is a partial answer, not a failed request: the envelope goes
      # out with the failure in `errors[]`, so a caller still learns which source broke and
      # what the query compiled to.
      {:error, reason} ->
        elapsed = System.monotonic_time(:millisecond) - started
        empty = %{records: [], native: "", total: 0}
        error = ResponseError.build(name, reason)
        {:ok, Response.query_envelope(name, empty, query.mode, elapsed, [error])}
    end
  end

  defp run_query(%{sources: nil}, _caller) do
    invalid_query("sources is required — name exactly one source")
  end

  # Matches [] and [_, _ | _] alike: anything that is not exactly one source.
  defp run_query(%{sources: _}, _caller) do
    {:error,
     %{
       error: "unsupported",
       message:
         "`sources` must name exactly one source — querying several at once is not " <>
           "supported. Issue one query per source, or use /v1/context to correlate " <>
           "across every configured source in a single call."
     }}
  end

  # A limit the caller did not send is ours to choose, so it is kept inside their
  # policy's cap rather than refused for exceeding it. A limit they did send is checked
  # as given.
  defp default_limit(%Caller{policy: policy}) do
    case Policy.limit_cap(policy) do
      nil -> Response.default_limit()
      cap -> min(cap, Response.default_limit())
    end
  end

  defp forbidden(message), do: {:error, %{error: "forbidden", message: message}}

  defp invalid_query(message), do: {:error, %{error: "invalid_query", message: message}}
end
