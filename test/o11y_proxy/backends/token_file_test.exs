defmodule O11yProxy.Backends.TokenFileTest do
  use ExUnit.Case, async: true

  alias O11yProxy.Backends.TokenFile

  @moduletag :tmp_dir

  defp write(dir, contents) do
    path = Path.join(dir, "token")
    File.write!(path, contents)
    path
  end

  test "reads the token, without the trailing newline a Secret usually has", %{tmp_dir: dir} do
    assert {:ok, "eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJ4In0.c2ln"} =
             TokenFile.read(write(dir, "eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJ4In0.c2ln\n"))
  end

  test "accepts the whole b64token alphabet, padding included", %{tmp_dir: dir} do
    assert {:ok, "aZ09-._~+/=="} = TokenFile.read(write(dir, "  aZ09-._~+/==  "))
  end

  test "rereads the file each time, so a rotated token is picked up", %{tmp_dir: dir} do
    path = write(dir, "first")
    assert {:ok, "first"} = TokenFile.read(path)

    File.write!(path, "second\n")
    assert {:ok, "second"} = TokenFile.read(path)
  end

  test "follows a symlink, as a Kubernetes Secret volume uses", %{tmp_dir: dir} do
    target = write(dir, "linked")
    link = Path.join(dir, "link")
    File.ln_s!(target, link)

    assert {:ok, "linked"} = TokenFile.read(link)
  end

  test "an empty or missing file may turn up, so it is unavailable", %{tmp_dir: dir} do
    for contents <- ["", "\n", "   \n"] do
      assert {:error, {:unavailable, "the token file is empty"}} =
               TokenFile.read(write(dir, contents))
    end

    assert {:error, {:unavailable, message}} = TokenFile.read(Path.join(dir, "missing"))
    assert message == "the token file could not be read: no such file or directory"
  end

  test "a file that exists but cannot be read stays that way, so it is invalid",
       %{tmp_dir: dir} do
    unreadable = write(dir, "token")
    File.chmod!(unreadable, 0o000)

    assert {:error, {:invalid, "the token file could not be read: permission denied"}} =
             TokenFile.read(unreadable)

    assert {:error, {:invalid, "the token file could not be read: not a directory"}} =
             TokenFile.read(Path.join(unreadable, "token"))
  end

  test "a file holding anything but one bearer token is invalid", %{tmp_dir: dir} do
    for contents <- [~s({"token": "abc"}), "abc\ndef", "abc def", "abc\r\nX-Injected: 1", "=abc"] do
      assert {:error, {:invalid, message}} = TokenFile.read(write(dir, contents))
      assert message =~ "does not hold a single bearer token"
    end
  end

  test "a file far bigger than any token is invalid, and not read whole", %{tmp_dir: dir} do
    assert {:error, {:invalid, message}} =
             TokenFile.read(write(dir, String.duplicate("a", 64 * 1024 + 1)))

    assert message =~ "over 64 KB"

    assert {:ok, _} = TokenFile.read(write(dir, String.duplicate("a", 64 * 1024)))
  end

  test "refuses what is not a regular file, without blocking on a named pipe",
       %{tmp_dir: dir} do
    assert {:error, {:invalid, "the token file is a directory, not a regular file"}} =
             TokenFile.read(dir)

    fifo = Path.join(dir, "fifo")
    {_, 0} = System.cmd("mkfifo", [fifo])

    assert {:error,
            {:invalid,
             "the token file is a pipe, socket or other special file, not a regular file"}} =
             TokenFile.read(fifo)
  end

  test "never names the path in a message", %{tmp_dir: dir} do
    for path <- [Path.join(dir, "missing"), dir, write(dir, "a b")] do
      assert {:error, {_kind, message}} = TokenFile.read(path)
      refute message =~ dir
    end
  end
end
