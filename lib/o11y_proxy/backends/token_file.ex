defmodule O11yProxy.Backends.TokenFile do
  @moduledoc """
  Reads a backend's bearer token from a file that something else keeps fresh: a token
  broker's sidecar or operator writing a Kubernetes Secret, a projected service account
  token, a cron job. The proxy never refreshes the token itself, so it needs no
  credentials for the broker and no knowledge of which broker it is.

  The file is read on every request rather than cached. A rotated token is then used on
  the very next request, with no watcher and no expiry to track, and a Kubernetes Secret
  volume swaps its files atomically by symlink, so a read never sees half a token. One
  small file read is noise next to the HTTP request it authorizes.
  """

  # A JWT is a few KB. Anything far bigger is the wrong file, and not worth reading whole.
  @max_bytes 64 * 1024

  @doc """
  The token in `path`, without the trailing newline most writers leave.

  Refuses an empty file, and anything that is not a single RFC 6750 `b64token`: a file
  holding JSON, or two lines, is the wrong file, and sending it would only fail upstream
  with a less useful message.

  The reason in an error never names the path. It reaches callers, who have no use for
  the proxy's file layout; the operator has the path in config.
  """
  @spec read(Path.t()) :: {:ok, String.t()} | {:error, String.t()}
  def read(path) do
    with {:ok, contents} <- read_bounded(path), do: token(String.trim(contents))
  end

  defp token(""), do: {:error, "the token file is empty"}

  defp token(token) do
    if b64token?(token),
      do: {:ok, token},
      else: {:error, "the token file does not hold a single bearer token (one line, no spaces)"}
  end

  defp read_bounded(path) do
    case File.open(path, [:read, :binary], &IO.binread(&1, @max_bytes + 1)) do
      {:ok, data} when is_binary(data) and byte_size(data) > @max_bytes ->
        {:error, "the token file is over #{div(@max_bytes, 1024)} KB, so it is not a token"}

      {:ok, data} when is_binary(data) ->
        {:ok, data}

      {:ok, :eof} ->
        {:ok, ""}

      {:ok, {:error, reason}} ->
        unreadable(reason)

      {:error, reason} ->
        unreadable(reason)
    end
  end

  defp unreadable(reason), do: {:error, "the token file could not be read (#{reason})"}

  # RFC 6750 §2.1: 1*( ALPHA / DIGIT / "-" / "." / "_" / "~" / "+" / "/" ) *"="
  defp b64token?(token), do: token =~ ~r/\A[A-Za-z0-9\-._~+\/]+=*\z/
end
