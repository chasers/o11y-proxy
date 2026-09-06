defmodule O11yProxy.Config.Source do
  @moduledoc """
  One validated `sources:` entry from `o11y.yaml` — a configured instance of a backend
  (e.g. `app_logs`, a ClickHouse source over `otel_logs`). See "Source vs backend" in
  `.plans/00-overview.md`.
  """

  @enforce_keys [:name, :backend, :backend_name, :signal, :opts]
  defstruct [:name, :backend, :backend_name, :signal, :opts]

  @type t :: %__MODULE__{
          name: String.t(),
          backend: module(),
          backend_name: String.t(),
          signal: :logs | :metrics | :traces | :errors,
          opts: map()
        }
end
