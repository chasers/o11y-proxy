defmodule O11yProxy.Backends.VictoriaMetrics.CursorTest do
  @moduledoc """
  `init/1` and `compile/2` do no network I/O (per the `O11yProxy.Backend` contract), so
  cursor rejection is testable directly without the `:victoriametrics` live tag — unlike
  `execute/2`, which needs a real instance and is covered by the tagged
  `victoria_metrics_test.exs` `BackendCase` suite instead.
  """

  use ExUnit.Case, async: true

  alias O11yProxy.Backends.VictoriaMetrics
  alias O11yProxy.Query

  setup do
    {:ok, state} =
      VictoriaMetrics.init(%{
        url: "http://localhost:8428",
        base_path: "",
        auth: "none",
        username: "",
        password: "",
        token: "",
        allow_raw: true,
        timeout_ms: 30_000,
        summary_points: 50,
        full_points: 500
      })

    %{state: state}
  end

  defp query(overrides) do
    struct(
      %Query{
        signal: :metrics,
        from: ~U[2026-09-05 19:00:00Z],
        to: ~U[2026-09-05 20:00:00Z],
        filters: [%Query.Filter{field: "name", op: :eq, value: "up"}]
      },
      overrides
    )
  end

  test "compile/2 succeeds with no cursor", %{state: state} do
    assert {:ok, _native} = VictoriaMetrics.compile(state, query(%{cursor: nil}))
  end

  test "compile/2 rejects an incoming cursor with a clear, honest error", %{state: state} do
    assert {:error, {:invalid_cursor, message}} =
             VictoriaMetrics.compile(state, query(%{cursor: "some-cursor"}))

    assert message =~ "metrics don't support pagination"
  end

  test "compile/2 rejects a cursor even on a raw query", %{state: state} do
    assert {:error, {:invalid_cursor, _}} =
             VictoriaMetrics.compile(state, query(%{raw: "up", cursor: "some-cursor"}))
  end
end
