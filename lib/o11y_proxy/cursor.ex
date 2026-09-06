defmodule O11yProxy.Cursor do
  @moduledoc """
  Opaque pagination cursors — "opaque cursors, no offset math in the agent".
  Every adapter's native pagination token (a ClickHouse
  timestamp bound, a raw Sentry `Link`-header cursor, ...) gets wrapped with the backend
  name that produced it before being handed to the caller, so:

    * decoding never needs `:erlang.binary_to_term` on caller-supplied input — that's an
      unsafe-deserialization footgun on untrusted data; base64(JSON) is inspectable and
      has no code-execution surface.
    * a cursor minted by one backend, replayed against a different one (by mistake, or a
      confused agent copy-pasting across sources), fails cleanly as an `invalid_query`
      instead of being handed raw to a native API that doesn't understand it.
  """

  @doc "Wraps a backend's native cursor data into an opaque token."
  @spec encode(String.t(), map()) :: String.t()
  def encode(backend_name, native) when is_binary(backend_name) and is_map(native) do
    %{"backend" => backend_name, "native" => native}
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  @doc """
  Unwraps a token minted by `encode/2`, verifying it was minted for `backend_name`.
  Never raises on malformed input — any failure (bad base64, bad JSON, wrong backend)
  becomes `{:error, :invalid_cursor}`.
  """
  @spec decode(String.t(), String.t()) :: {:ok, map()} | {:error, :invalid_cursor}
  def decode(token, backend_name) when is_binary(token) and is_binary(backend_name) do
    with {:ok, json} <- Base.url_decode64(token, padding: false),
         {:ok, %{"backend" => ^backend_name, "native" => native}} <- Jason.decode(json) do
      {:ok, native}
    else
      _ -> {:error, :invalid_cursor}
    end
  end

  def decode(_token, _backend_name), do: {:error, :invalid_cursor}
end
