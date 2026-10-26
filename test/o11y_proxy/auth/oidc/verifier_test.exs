defmodule O11yProxy.Auth.OIDC.VerifierTest do
  use ExUnit.Case, async: true

  alias O11yProxy.Auth.OIDC.Verifier
  alias O11yProxy.Test.OIDC

  setup_all do
    key = OIDC.key("k1")
    {:ok, keys} = Verifier.parse_jwks(OIDC.jwks([key]))
    %{key: key, public: Map.fetch!(keys, "k1")}
  end

  defp opts(overrides \\ []) do
    Keyword.merge(
      [
        issuer: OIDC.issuer(),
        audiences: [OIDC.audience()],
        algorithms: ["RS256"],
        leeway: 0,
        now: System.system_time(:second)
      ],
      overrides
    )
  end

  defp b64(map), do: map |> Jason.encode!() |> Base.url_encode64(padding: false)

  describe "verify/3 accepts" do
    test "a correctly signed token with matching claims", %{key: key, public: public} do
      token = OIDC.token(key, OIDC.claims(%{"sub" => "alice"}))
      assert {:ok, %{"sub" => "alice"}} = Verifier.verify(token, public, opts())
    end

    test "an aud list that contains this service", %{key: key, public: public} do
      token = OIDC.token(key, OIDC.claims(%{"aud" => ["other", OIDC.audience()]}))
      assert {:ok, _} = Verifier.verify(token, public, opts())
    end

    test "an expired token inside the leeway", %{key: key, public: public} do
      now = System.system_time(:second)
      token = OIDC.token(key, OIDC.claims(%{"exp" => now - 30}))
      assert {:ok, _} = Verifier.verify(token, public, opts(now: now, leeway: 60))
    end
  end

  describe "verify/3 rejects" do
    test "a different issuer", %{key: key, public: public} do
      token = OIDC.token(key, OIDC.claims(%{"iss" => "https://elsewhere.test"}))
      assert {:error, "token issuer is not trusted"} = Verifier.verify(token, public, opts())
    end

    test "an audience that does not include this service", %{key: key, public: public} do
      token = OIDC.token(key, OIDC.claims(%{"aud" => ["someone-else"]}))
      assert {:error, "token audience" <> _} = Verifier.verify(token, public, opts())
    end

    test "a token with no aud or no exp", %{key: key, public: public} do
      no_aud = OIDC.token(key, Map.delete(OIDC.claims(), "aud"))
      no_exp = OIDC.token(key, Map.delete(OIDC.claims(), "exp"))
      assert {:error, "token has no audience"} = Verifier.verify(no_aud, public, opts())
      assert {:error, "token has no expiry"} = Verifier.verify(no_exp, public, opts())
    end

    test "an expired token outside the leeway", %{key: key, public: public} do
      now = System.system_time(:second)
      token = OIDC.token(key, OIDC.claims(%{"exp" => now - 120}))

      assert {:error, "token has expired"} =
               Verifier.verify(token, public, opts(now: now, leeway: 60))
    end

    test "exp equal to now", %{key: key, public: public} do
      now = System.system_time(:second)
      token = OIDC.token(key, OIDC.claims(%{"exp" => now}))
      assert {:error, "token has expired"} = Verifier.verify(token, public, opts(now: now))
    end

    test "a token that is not valid yet", %{key: key, public: public} do
      now = System.system_time(:second)
      token = OIDC.token(key, OIDC.claims(%{"nbf" => now + 120}))
      assert {:error, "token is not valid yet"} = Verifier.verify(token, public, opts(now: now))
    end

    test "a token signed by a different key", %{public: public} do
      token = OIDC.token(OIDC.key("k1"), OIDC.claims())
      assert {:error, "token signature does not verify"} = Verifier.verify(token, public, opts())
    end

    test "a tampered payload", %{key: key, public: public} do
      [header, _payload, signature] = String.split(OIDC.token(key, OIDC.claims()), ".")
      forged = Enum.join([header, b64(OIDC.claims(%{"sub" => "admin"})), signature], ".")
      assert {:error, "token signature does not verify"} = Verifier.verify(forged, public, opts())
    end

    test "alg: none" do
      token = b64(%{"alg" => "none", "kid" => "k1"}) <> "." <> b64(OIDC.claims()) <> "."
      {:ok, keys} = Verifier.parse_jwks(OIDC.jwks([OIDC.key("k1")]))
      assert {:error, _} = Verifier.verify(token, keys["k1"], opts())
    end

    test "an HMAC token keyed with the issuer's public key (algorithm confusion)",
         %{key: key, public: public} do
      {_, pem} = key |> JOSE.JWK.to_public() |> JOSE.JWK.to_pem()
      hmac = JOSE.JWK.from_oct(pem)

      {_, token} =
        hmac
        |> JOSE.JWT.sign(%{"alg" => "HS256", "kid" => "k1"}, OIDC.claims())
        |> JOSE.JWS.compact()

      assert {:error, _} = Verifier.verify(token, public, opts())
    end

    test "an algorithm outside the configured allow-list", %{key: key, public: public} do
      token = OIDC.token(key, OIDC.claims())
      assert {:error, _} = Verifier.verify(token, public, opts(algorithms: ["ES256"]))
    end

    test "garbage", %{public: public} do
      for garbage <- ["", "abc", "a.b.c", "!!.##.$$"] do
        assert {:error, _} = Verifier.verify(garbage, public, opts())
      end
    end
  end

  describe "header/1" do
    test "decodes the protected header", %{key: key} do
      assert {:ok, %{"alg" => "RS256", "kid" => "k1"}} =
               Verifier.header(OIDC.token(key, OIDC.claims()))
    end

    test "refuses anything that is not three parts with a JSON object header" do
      for bad <- ["", "a.b", "a.b.c", b64(["list"]) <> ".e30.sig", "!!!.e30.sig"] do
        assert {:error, "bearer token is not a well-formed JWT"} = Verifier.header(bad)
      end
    end
  end

  describe "select_key/2" do
    test "matches by kid" do
      assert {:ok, :a} = Verifier.select_key(%{"k1" => :a, "k2" => :b}, %{"kid" => "k1"})
      assert :error = Verifier.select_key(%{"k1" => :a}, %{"kid" => "k9"})
    end

    test "uses the only key when the token has no kid, and refuses to guess between several" do
      assert {:ok, :a} = Verifier.select_key(%{"k1" => :a}, %{})
      assert :error = Verifier.select_key(%{"k1" => :a, "k2" => :b}, %{})
    end
  end

  describe "parse_jwks/1" do
    test "keeps RSA, EC and OKP signing keys" do
      ec = {:ec, "P-256"} |> JOSE.JWK.generate_key() |> JOSE.JWK.merge(%{"kid" => "ec"})
      ed = {:okp, :Ed25519} |> JOSE.JWK.generate_key() |> JOSE.JWK.merge(%{"kid" => "ed"})

      assert {:ok, keys} = Verifier.parse_jwks(OIDC.jwks([OIDC.key("rsa"), ec, ed]))
      assert keys |> Map.keys() |> Enum.sort() == ["ec", "ed", "rsa"]
    end

    test "drops symmetric, encryption and malformed keys without failing the set" do
      %{"keys" => [good]} = OIDC.jwks([OIDC.key("good")])

      document = %{
        "keys" => [
          good,
          %{"kty" => "oct", "k" => "c2VjcmV0", "kid" => "hmac"},
          Map.merge(good, %{"kid" => "enc", "use" => "enc"}),
          %{"kty" => "RSA", "kid" => "broken"},
          %{"kty" => "RSA", "kid" => "bad-b64", "n" => "!!", "e" => "AQAB"},
          %{"kty" => "EC", "kid" => "bad-curve", "crv" => "P-192", "x" => "AA", "y" => "AA"},
          "not a map"
        ]
      }

      assert {:ok, keys} = Verifier.parse_jwks(document)
      assert Map.keys(keys) == ["good"]
    end

    test "refuses a document with no keys list" do
      assert :error = Verifier.parse_jwks(%{})
      assert :error = Verifier.parse_jwks(%{"keys" => "nope"})
    end
  end
end
