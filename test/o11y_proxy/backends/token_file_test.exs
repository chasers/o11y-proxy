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

  test "refuses an empty file", %{tmp_dir: dir} do
    for contents <- ["", "\n", "   \n"] do
      assert {:error, "the token file is empty"} = TokenFile.read(write(dir, contents))
    end
  end

  test "refuses anything that is not one bearer token", %{tmp_dir: dir} do
    for contents <- [~s({"token": "abc"}), "abc\ndef", "abc def", "abc\r\nX-Injected: 1", "=abc"] do
      assert {:error, message} = TokenFile.read(write(dir, contents))
      assert message =~ "does not hold a single bearer token"
    end
  end

  test "refuses a file far bigger than any token, without reading it whole", %{tmp_dir: dir} do
    assert {:error, message} = TokenFile.read(write(dir, String.duplicate("a", 64 * 1024 + 1)))
    assert message =~ "over 64 KB"

    assert {:ok, _} = TokenFile.read(write(dir, String.duplicate("a", 64 * 1024)))
  end

  test "says why a file cannot be read, without naming its path", %{tmp_dir: dir} do
    missing = Path.join(dir, "missing")

    assert {:error, message} = TokenFile.read(missing)
    assert message =~ "could not be read (enoent)"
    refute message =~ dir

    assert {:error, message} = TokenFile.read(dir)
    assert message =~ "could not be read"
  end
end
