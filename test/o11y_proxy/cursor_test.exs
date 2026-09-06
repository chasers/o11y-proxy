defmodule O11yProxy.CursorTest do
  use ExUnit.Case, async: true

  alias O11yProxy.Cursor

  describe "encode/2 + decode/2" do
    test "round-trips native cursor data for the same backend" do
      token = Cursor.encode("clickhouse", %{"ts" => "2026-09-05T20:00:00Z"})
      assert {:ok, %{"ts" => "2026-09-05T20:00:00Z"}} = Cursor.decode(token, "clickhouse")
    end

    test "rejects a token decoded against the wrong backend name" do
      token = Cursor.encode("clickhouse", %{"ts" => "2026-09-05T20:00:00Z"})
      assert {:error, :invalid_cursor} = Cursor.decode(token, "sentry")
    end

    test "rejects garbage input rather than raising" do
      assert {:error, :invalid_cursor} = Cursor.decode("not a real cursor", "clickhouse")
      assert {:error, :invalid_cursor} = Cursor.decode("", "clickhouse")

      assert {:error, :invalid_cursor} =
               Cursor.decode(Base.url_encode64("not json"), "clickhouse")
    end

    test "rejects non-binary input rather than raising" do
      assert {:error, :invalid_cursor} = Cursor.decode(nil, "clickhouse")
      assert {:error, :invalid_cursor} = Cursor.decode(123, "clickhouse")
    end

    test "the token is base64(JSON), not an opaque binary term — inspectable, no code-exec surface" do
      token = Cursor.encode("clickhouse", %{"ts" => "x"})
      assert {:ok, json} = Base.url_decode64(token, padding: false)
      assert %{"backend" => "clickhouse", "native" => %{"ts" => "x"}} = Jason.decode!(json)
    end
  end
end
