defmodule O11yProxy.Auth.OIDC.Keys do
  @moduledoc """
  Owns the issuer's signing keys: discovers the JWKS, keeps it fresh, and serves lookups.

  Keys are published to a protected ETS table so a request verifies a token without a
  round trip through this process; only a fetch is serialised here. The table holds one
  entry, replaced whole, so a reader never sees half of a rotation.

  Fetching follows OIDC discovery (`{issuer}/.well-known/openid-configuration` →
  `jwks_uri`) unless `jwks_uri` is configured directly, for issuers that publish keys but
  no discovery document. Keys are refreshed on an interval, and once more on demand when a
  token names a `kid` the cached set does not have — the normal shape of a key rotation,
  where the issuer starts signing with a new key a little before every cache has seen it.

  That on-demand refetch is rate limited (`min_refetch_ms`, 10s by default). Without it,
  anyone able to send a request could make this process hammer the issuer simply by
  inventing `kid`s.

  A failed fetch keeps the keys already held, logs, and retries with backoff. Until the
  first fetch succeeds there are no keys, and `lookup/1` answers `{:error, :unavailable}`,
  which the auth plug turns into a 503: the server is up but cannot verify anyone yet,
  which is different from the caller being wrong.
  """

  use GenServer
  require Logger

  alias O11yProxy.Auth.OIDC.Verifier

  @table __MODULE__
  @call_timeout 10_000
  @initial_retry_ms 1_000

  @doc """
  `opts` is the validated `server.oidc` map, plus two internal keys: `:min_refetch_ms`
  and `:req_options`, merged into every `Req` call (tests point it at `Req.Test`).
  """
  @spec start_link(map()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  The verifying key and accepted algorithms for a token header. Refetches the key set at
  most once, rate limited, when the header names a `kid` that is not held.
  """
  @spec lookup(map()) ::
          {:ok, JOSE.JWK.t(), [String.t()]} | {:error, :unavailable | :unknown_key}
  def lookup(header) do
    with {:ok, keys, algorithms} <- current() do
      case Verifier.select_key(keys, header) do
        {:ok, jwk} -> {:ok, jwk, algorithms}
        :error -> refetch_and_select(header)
      end
    end
  end

  defp refetch_and_select(header) do
    :ok = GenServer.call(__MODULE__, :refetch, @call_timeout)

    with {:ok, keys, algorithms} <- current() do
      case Verifier.select_key(keys, header) do
        {:ok, jwk} -> {:ok, jwk, algorithms}
        :error -> {:error, :unknown_key}
      end
    end
  catch
    # The key process is down or wedged: that is the server being unable to verify, not
    # the caller presenting a bad token.
    :exit, _reason -> {:error, :unavailable}
  end

  defp current do
    case :ets.whereis(@table) do
      :undefined ->
        {:error, :unavailable}

      _tid ->
        case :ets.lookup(@table, :keyset) do
          [{:keyset, keys, algorithms}] -> {:ok, keys, algorithms}
          [] -> {:error, :unavailable}
        end
    end
  end

  # -- server ----------------------------------------------------------------------------

  @impl true
  def init(opts) do
    :ets.new(@table, [:named_table, :protected, read_concurrency: true])

    state = %{
      opts: opts,
      req_options: Map.get(opts, :req_options, []),
      min_refetch_ms: Map.get(opts, :min_refetch_ms, 10_000),
      refresh_ms: opts.jwks_refresh_seconds * 1_000,
      retry_ms: @initial_retry_ms,
      last_fetch: nil,
      timer: nil
    }

    {:ok, state, {:continue, :fetch}}
  end

  @impl true
  def handle_continue(:fetch, state), do: {:noreply, fetch_and_schedule(state)}

  @impl true
  def handle_info(:refresh, state), do: {:noreply, fetch_and_schedule(state)}

  @impl true
  def handle_call(:refetch, _from, state) do
    now = System.monotonic_time(:millisecond)

    if state.last_fetch && now - state.last_fetch < state.min_refetch_ms do
      {:reply, :ok, state}
    else
      {:reply, :ok, fetch_and_schedule(state)}
    end
  end

  defp fetch_and_schedule(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    state = %{state | last_fetch: System.monotonic_time(:millisecond)}

    case fetch(state) do
      {:ok, keys, algorithms} ->
        :ets.insert(@table, {:keyset, keys, algorithms})
        timer = Process.send_after(self(), :refresh, state.refresh_ms)
        %{state | retry_ms: @initial_retry_ms, timer: timer}

      {:error, message} ->
        Logger.warning(
          "o11y-proxy: could not load signing keys for #{state.opts.issuer}: #{message}; " <>
            "retrying in #{div(state.retry_ms, 1_000)}s"
        )

        timer = Process.send_after(self(), :refresh, state.retry_ms)
        %{state | retry_ms: min(state.retry_ms * 2, state.refresh_ms), timer: timer}
    end
  end

  defp fetch(state) do
    with {:ok, jwks_uri, advertised} <- discover(state),
         {:ok, document} <- get_json(jwks_uri, state) do
      case Verifier.parse_jwks(document) do
        {:ok, keys} when map_size(keys) > 0 ->
          {:ok, keys, algorithms(state.opts, advertised)}

        _ ->
          {:error, "#{jwks_uri} holds no usable signing keys"}
      end
    end
  end

  defp discover(%{opts: %{jwks_uri: uri}}) when is_binary(uri), do: {:ok, uri, nil}

  defp discover(%{opts: %{issuer: issuer}} = state) do
    url = String.trim_trailing(issuer, "/") <> "/.well-known/openid-configuration"

    with {:ok, document} <- get_json(url, state) do
      case document do
        # OIDC discovery requires the document's issuer to equal the one it was fetched
        # for; a mismatch means the URL points at someone else's keys.
        %{"issuer" => ^issuer, "jwks_uri" => jwks_uri} when is_binary(jwks_uri) ->
          {:ok, jwks_uri, Map.get(document, "id_token_signing_alg_values_supported")}

        %{"issuer" => other} ->
          {:error, "#{url} names issuer #{inspect(other)}, expected #{inspect(issuer)}"}

        _ ->
          {:error, "#{url} has no jwks_uri"}
      end
    end
  end

  # Configured algorithms are authoritative. Without them, follow what the issuer
  # advertises — so an issuer moving from RS256 to ES256 needs no config change — but
  # only ever the asymmetric ones, and RS256 when the issuer says nothing.
  defp algorithms(%{algorithms: configured}, _advertised) when is_list(configured),
    do: configured

  defp algorithms(_opts, advertised) when is_list(advertised) do
    case Enum.filter(advertised, &(&1 in Verifier.supported_algorithms())) do
      [] -> ["RS256"]
      usable -> usable
    end
  end

  defp algorithms(_opts, _advertised), do: ["RS256"]

  defp get_json(url, state) do
    case Req.get(url, [receive_timeout: 5_000, retry: false] ++ state.req_options) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        case Jason.decode(body) do
          {:ok, %{} = decoded} -> {:ok, decoded}
          _ -> {:error, "#{url} did not return a JSON object"}
        end

      {:ok, %Req.Response{status: status}} ->
        {:error, "#{url} returned HTTP #{status}"}

      {:error, exception} ->
        {:error, "#{url} is unreachable: #{Exception.message(exception)}"}
    end
  end
end
