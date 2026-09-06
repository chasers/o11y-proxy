defmodule O11yProxy.Backends do
  @moduledoc """
  Resolves a config file's `backend:` string to an adapter module. Adapters are
  discovered from config, not a compile-time list — third parties register by adding to
  `config :o11y_proxy, :backends`, merged over the defaults below.
  """

  @default %{
    "clickhouse" => O11yProxy.Backends.ClickHouse,
    "victoriametrics" => O11yProxy.Backends.VictoriaMetrics,
    "sentry" => O11yProxy.Backends.Sentry,
    "logflare" => O11yProxy.Backends.Logflare
  }

  @spec registry() :: %{optional(String.t()) => module()}
  def registry do
    Map.merge(@default, Application.get_env(:o11y_proxy, :backends, %{}))
  end

  @spec resolve(String.t()) :: {:ok, module()} | {:error, {:unknown_backend, String.t()}}
  def resolve(name) when is_binary(name) do
    case Map.fetch(registry(), name) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, {:unknown_backend, name}}
    end
  end
end
