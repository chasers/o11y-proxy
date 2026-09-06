defmodule O11yProxy.Backends.Sentry.CursorTest do
  @moduledoc """
  Pure tests for Sentry's cursor plumbing: `Link`-header parsing and the
  `O11yProxy.Cursor` wrap/unwrap round trip through `compile/2`. The `Link` fixtures are
  the exact header shape captured live from
  `GET /organizations/{org}/issues/` on 2026-09-06 (org/project slugs scrubbed), so this
  tests the real format rather than an assumed one. No network needed —
  `init/1`/`compile/2` do no I/O per the `O11yProxy.Backend` contract.
  """

  use ExUnit.Case, async: true

  alias O11yProxy.Backends.Sentry
  alias O11yProxy.{Cursor, Query}

  @next_cursor "1785381220000:1:0"

  # Captured live, scrubbed: two comma-separated segments, previous then next.
  defp link_header(next_results) do
    ~s|<https://sentry.io/api/0/organizations/acme/issues/?project=checkout-api&limit=2&cursor=1788700125000:0:1>; | <>
      ~s|rel="previous"; results="false"; cursor="1788700125000:0:1", | <>
      ~s|<https://sentry.io/api/0/organizations/acme/issues/?project=checkout-api&limit=2&cursor=#{@next_cursor}>; | <>
      ~s|rel="next"; results="#{next_results}"; cursor="#{@next_cursor}"|
  end

  setup do
    {:ok, state} =
      Sentry.init(%{
        org: "acme",
        project: "checkout-api",
        token: "unset",
        base_url: "https://sentry.io/api/0",
        allow_raw: true,
        timeout_ms: 30_000
      })

    %{state: state}
  end

  defp query(overrides) do
    struct(
      %Query{
        signal: :errors,
        from: ~U[2026-09-05 19:00:00Z],
        to: ~U[2026-09-05 20:00:00Z],
        mode: :full,
        limit: 50
      },
      overrides
    )
  end

  describe "parse_next_cursor/1" do
    test "extracts the rel=next cursor when Sentry says there are more results" do
      headers = %{"link" => [link_header("true")]}
      assert Sentry.parse_next_cursor(headers) == @next_cursor
    end

    test "returns nil when Sentry says the next page is empty (results=false)" do
      headers = %{"link" => [link_header("false")]}
      assert Sentry.parse_next_cursor(headers) == nil
    end

    test "does not mistake the rel=previous segment for the next one" do
      previous_only =
        "<https://sentry.io/api/0/organizations/acme/issues/?cursor=abc>; " <>
          "rel=\"previous\"; results=\"true\"; cursor=\"abc\""

      assert Sentry.parse_next_cursor(%{"link" => [previous_only]}) == nil
    end

    test "returns nil when there is no Link header at all" do
      assert Sentry.parse_next_cursor(%{}) == nil
    end
  end

  describe "compile/2 cursor handling" do
    test "compiles with no cursor by default", %{state: state} do
      assert {:ok, %{cursor: nil}} = Sentry.compile(state, query(%{}))
    end

    test "unwraps our opaque token back to Sentry's native cursor", %{state: state} do
      token = Cursor.encode("sentry", %{"cursor" => @next_cursor})
      assert {:ok, %{cursor: @next_cursor}} = Sentry.compile(state, query(%{cursor: token}))
    end

    test "rejects a cursor minted by a different backend", %{state: state} do
      token = Cursor.encode("clickhouse", %{"ts" => "2026-09-05T19:00:00Z"})
      assert {:error, {:invalid_cursor, ^token}} = Sentry.compile(state, query(%{cursor: token}))
    end

    test "rejects garbage rather than passing it through to Sentry's API", %{state: state} do
      assert {:error, {:invalid_cursor, "garbage"}} =
               Sentry.compile(state, query(%{cursor: "garbage"}))
    end

    test "also applies on the raw path", %{state: state} do
      assert {:error, {:invalid_cursor, "garbage"}} =
               Sentry.compile(state, query(%{raw: "is:unresolved", cursor: "garbage"}))
    end

    test "a structurally valid envelope with the wrong payload is a bad cursor, not a crash",
         %{state: state} do
      # Decodes fine as ours, but carries no usable native token — must be a 400-shaped
      # error rather than falling through to a CaseClauseError and a 500.
      for payload <- [%{}, %{"cursor" => 123}, %{"nope" => "x"}] do
        token = Cursor.encode("sentry", payload)

        assert {:error, {:invalid_cursor, ^token}} =
                 Sentry.compile(state, query(%{cursor: token}))
      end
    end
  end
end
