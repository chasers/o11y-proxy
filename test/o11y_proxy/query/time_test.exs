defmodule O11yProxy.Query.TimeTest do
  use ExUnit.Case, async: true

  alias O11yProxy.Query.Time

  @now ~U[2026-09-05 20:00:00Z]

  test "now resolves to the anchor" do
    assert {:ok, @now} = Time.parse("now", @now)
  end

  test "relative minus resolves to the past" do
    assert {:ok, ~U[2026-09-05 19:45:00Z]} = Time.parse("now-15m", @now)
  end

  test "relative plus resolves to the future" do
    assert {:ok, ~U[2026-09-05 21:00:00Z]} = Time.parse("now+1h", @now)
  end

  test "supports every unit" do
    assert {:ok, ~U[2026-09-05 19:59:59Z]} = Time.parse("now-1s", @now)
    assert {:ok, ~U[2026-09-04 20:00:00Z]} = Time.parse("now-1d", @now)
    assert {:ok, ~U[2026-08-29 20:00:00Z]} = Time.parse("now-1w", @now)
  end

  test "absolute RFC3339 timestamps parse and normalize to UTC" do
    assert {:ok, dt} = Time.parse("2026-09-05T10:00:00Z", @now)
    assert dt.time_zone == "Etc/UTC"
    assert DateTime.to_iso8601(dt) == "2026-09-05T10:00:00Z"
  end

  test "garbage is a structured error, not a crash" do
    assert {:error, _} = Time.parse("whenever", @now)
    assert {:error, _} = Time.parse("now-15x", @now)
  end
end
