defmodule O11yProxy.Auth.OIDC.KeysTest do
  # One named process and one named ETS table per node, so these cannot run concurrently.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias O11yProxy.Auth.OIDC.Keys
  alias O11yProxy.Test.OIDC

  setup_all do
    %{k1: OIDC.key("k1"), k2: OIDC.key("k2")}
  end

  test "is unavailable before it has started" do
    assert {:error, :unavailable} = Keys.lookup(%{"kid" => "k1"})
  end

  test "loads keys through discovery and serves them by kid", %{k1: k1} do
    issuer = OIDC.start_issuer([k1])
    OIDC.start_keys(issuer)

    assert {:ok, %JOSE.JWK{}, ["RS256"]} = Keys.lookup(%{"kid" => "k1"})
  end

  test "uses a configured jwks_uri without fetching discovery", %{k1: k1} do
    issuer = OIDC.start_issuer([k1], %{"jwks_uri" => "https://wrong.test/nope"})
    OIDC.start_keys(issuer, %{jwks_uri: OIDC.issuer() <> "/jwks"})

    assert {:ok, _jwk, _algorithms} = Keys.lookup(%{"kid" => "k1"})
  end

  test "follows the issuer's advertised algorithms unless configured", %{k1: k1} do
    issuer =
      OIDC.start_issuer([k1], %{
        "id_token_signing_alg_values_supported" => ["RS256", "HS256", "ES256"]
      })

    OIDC.start_keys(issuer)

    # HS256 is advertised but symmetric, so it is never accepted.
    assert {:ok, _jwk, ["RS256", "ES256"]} = Keys.lookup(%{"kid" => "k1"})
  end

  test "configured algorithms win over the advertised ones", %{k1: k1} do
    issuer = OIDC.start_issuer([k1])
    OIDC.start_keys(issuer, %{algorithms: ["PS256"]})

    assert {:ok, _jwk, ["PS256"]} = Keys.lookup(%{"kid" => "k1"})
  end

  test "refetches once for an unknown kid, picking up a rotated key", %{k1: k1, k2: k2} do
    issuer = OIDC.start_issuer([k1])
    OIDC.start_keys(issuer, %{min_refetch_ms: 0})
    assert OIDC.fetches(issuer) == 1

    OIDC.rotate(issuer, [k1, k2])
    assert {:ok, _jwk, _algorithms} = Keys.lookup(%{"kid" => "k2"})
    assert OIDC.fetches(issuer) == 2
  end

  test "rate limits refetches, so invented kids cannot hammer the issuer", %{k1: k1} do
    issuer = OIDC.start_issuer([k1])
    OIDC.start_keys(issuer, %{min_refetch_ms: 60_000})

    for n <- 1..20, do: assert({:error, :unknown_key} = Keys.lookup(%{"kid" => "invented-#{n}"}))
    assert OIDC.fetches(issuer) == 1
  end

  test "refuses a discovery document that names another issuer", %{k1: k1} do
    issuer = OIDC.start_issuer([k1], %{"issuer" => "https://impostor.test"})

    log = capture_log(fn -> OIDC.start_keys(issuer) end)

    assert log =~ "names issuer \"https://impostor.test\""
    assert {:error, :unavailable} = Keys.lookup(%{"kid" => "k1"})
  end

  test "is unavailable, not failing callers' tokens, while the issuer is down", %{k1: k1} do
    issuer = OIDC.start_issuer([k1])
    OIDC.take_down(issuer)

    log = capture_log(fn -> OIDC.start_keys(issuer) end)

    assert log =~ "returned HTTP 503"
    assert {:error, :unavailable} = Keys.lookup(%{"kid" => "k1"})
  end

  test "keeps the keys it holds when a refresh fails", %{k1: k1} do
    issuer = OIDC.start_issuer([k1])
    pid = OIDC.start_keys(issuer)
    OIDC.take_down(issuer)

    capture_log(fn ->
      send(pid, :refresh)
      _ = :sys.get_state(pid)
    end)

    assert {:ok, _jwk, _algorithms} = Keys.lookup(%{"kid" => "k1"})
  end

  test "refuses a key set with no usable signing key" do
    issuer = OIDC.start_issuer([])

    log = capture_log(fn -> OIDC.start_keys(issuer) end)

    assert log =~ "holds no usable signing keys"
  end
end
