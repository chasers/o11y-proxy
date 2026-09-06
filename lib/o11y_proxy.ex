defmodule O11yProxy do
  @moduledoc """
  An agent-friendly observability proxy.
  """

  @doc "The OpenAPI document served at `GET /openapi.json`, read once and cached."
  @spec openapi_spec() :: String.t()
  def openapi_spec do
    :persistent_term.get({__MODULE__, :openapi_spec}, nil) || load_openapi_spec()
  end

  defp load_openapi_spec do
    spec =
      :o11y_proxy
      |> Application.app_dir("priv/static/openapi.json")
      |> File.read!()

    :persistent_term.put({__MODULE__, :openapi_spec}, spec)
    spec
  end
end
