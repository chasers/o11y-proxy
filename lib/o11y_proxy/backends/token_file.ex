defmodule O11yProxy.Backends.TokenFile do
  @moduledoc """
  Reads a backend's bearer token from a file that something else keeps fresh: a token
  broker's sidecar or operator writing a Kubernetes Secret, a projected service account
  token, a cron job. The proxy never refreshes the token itself, so it needs no
  credentials for the broker and no knowledge of which broker it is.

  The file is read per request rather than cached. A rotated token is then used on the
  very next request, with no watcher and no expiry to track, and a Kubernetes Secret
  volume swaps its files atomically by symlink, so a read never sees half a token. One
  small file read is noise next to the HTTP request it authorizes.
  """

  # A JWT is a few KB. Anything far bigger is the wrong file, and not worth reading whole.
  @max_bytes 64 * 1024

  @typedoc """
  `:unavailable` may fix itself: the file is not written yet, or is mid-refresh.
  `:invalid` will not: the path names something that is not a token file, or that the
  proxy is not allowed to read.
  """
  @type failure :: {:unavailable | :invalid, String.t()}

  @doc """
  The token in `path`, without the trailing newline most writers leave.

  Refuses anything that is not a regular file holding a single RFC 6750 `b64token`: a
  named pipe would block the read, and a file holding JSON, or two lines, is the wrong
  file, which sent anyway would only fail upstream with a less useful message.

  The message in an error never names the path. It reaches callers, who have no use for
  the proxy's file layout; the operator has the path in config.
  """
  @spec read(Path.t()) :: {:ok, String.t()} | {:error, failure()}
  def read(path) do
    with {:ok, contents} <- read_bounded(path), do: token(String.trim(contents))
  end

  # stat follows symlinks, so a Secret's symlinked file counts as the regular file it is.
  defp read_bounded(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size > @max_bytes ->
        too_big()

      {:ok, %File.Stat{type: :regular}} ->
        read_regular(path)

      {:ok, %File.Stat{type: type}} ->
        {:error, {:invalid, "the token file is #{file_kind(type)}, not a regular file"}}

      {:error, reason} ->
        unreadable(reason)
    end
  end

  # Bounded again, since the file can grow between the stat and the read.
  defp read_regular(path) do
    case File.open(path, [:read, :binary], &IO.binread(&1, @max_bytes + 1)) do
      {:ok, data} when is_binary(data) and byte_size(data) <= @max_bytes -> {:ok, data}
      {:ok, data} when is_binary(data) -> too_big()
      {:ok, :eof} -> {:ok, ""}
      {:ok, {:error, reason}} -> unreadable(reason)
      {:error, reason} -> unreadable(reason)
    end
  end

  defp too_big,
    do:
      {:error,
       {:invalid, "the token file is over #{div(@max_bytes, 1024)} KB, so it is not a token"}}

  defp file_kind(:directory), do: "a directory"
  defp file_kind(:device), do: "a device"
  defp file_kind(_other), do: "a pipe, socket or other special file"

  # Only a file that is not there yet may turn up by itself. Permissions, a path through a
  # non-directory, a symlink loop: those stay wrong until someone fixes the config.
  defp unreadable(reason) do
    kind = if reason == :enoent, do: :unavailable, else: :invalid
    {:error, {kind, "the token file could not be read: #{:file.format_error(reason)}"}}
  end

  # Empty is what a writer that truncates before writing leaves for a moment, so it is
  # worth retrying rather than a config mistake. The same writer can also leave half a
  # token for a moment, which reads as a valid one; the backend refuses it, and that comes
  # back as `:credential_rejected`, which is kept out of the circuit breaker too.
  defp token(""), do: {:error, {:unavailable, "the token file is empty"}}

  defp token(token) do
    if b64token?(token),
      do: {:ok, token},
      else:
        {:error,
         {:invalid, "the token file does not hold a single bearer token (one line, no spaces)"}}
  end

  # RFC 6750 §2.1: 1*( ALPHA / DIGIT / "-" / "." / "_" / "~" / "+" / "/" ) *"="
  defp b64token?(token), do: token =~ ~r/\A[A-Za-z0-9\-._~+\/]+=*\z/
end
