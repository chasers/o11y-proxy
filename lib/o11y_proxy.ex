defmodule O11yProxy do
  @moduledoc """
  An agent-friendly observability proxy.
  """

  @doc """
  The OpenAPI document served at `GET /openapi.json`, read once and cached.

  Served byte-for-byte from `priv/static/openapi.json` — key order and formatting
  included, so what a human curls is what is committed. Its `info.version` had drifted to
  `0.1.0-design` across two releases; rather than rewrite the field at runtime and let the
  committed file stay wrong, `O11yProxyTest` fails when it doesn't match the application
  version. Bumping the version in `mix.exs` and nowhere else now breaks the build.
  """
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
