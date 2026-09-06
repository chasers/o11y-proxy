defmodule O11yProxyTest do
  use ExUnit.Case, async: true

  test "openapi_spec/0 returns the served spec, matching the served copy" do
    assert O11yProxy.openapi_spec() ==
             File.read!(Application.app_dir(:o11y_proxy, "priv/static/openapi.json"))
  end

  # The spec is served byte-for-byte from the file, so its `info.version` is whatever
  # someone last typed there — and it had drifted to "0.1.0-design" across two releases,
  # telling every agent that reads the contract it was talking to a design-stage stub.
  # Nothing else forces the two to agree, so this does.
  test "the spec's info.version matches the application version" do
    spec = Jason.decode!(O11yProxy.openapi_spec())
    {:ok, vsn} = :application.get_key(:o11y_proxy, :vsn)

    assert spec["info"]["version"] == List.to_string(vsn),
           "priv/static/openapi.json says #{inspect(spec["info"]["version"])} but the " <>
             "app is #{List.to_string(vsn)} — bump `info.version` in the spec too."
  end

  # `/openapi.json` is what an agent reads to learn the API. Every route the router
  # actually serves has to be in it, or the agent never learns the endpoint exists.
  test "every route the router serves is documented" do
    documented = O11yProxy.openapi_spec() |> Jason.decode!() |> Map.fetch!("paths") |> Map.keys()

    served =
      "lib/o11y_proxy/router.ex"
      |> File.read!()
      |> then(&Regex.scan(~r/^\s+(?:get|post) "([^"]+)"/m, &1))
      |> Enum.map(fn [_, path] -> String.replace(path, ":name", "{name}") end)

    assert served != [], "could not read routes out of router.ex — did the file move?"

    assert Enum.sort(served) == Enum.sort(documented),
           "served but undocumented: #{inspect(served -- documented)}; " <>
             "documented but not served: #{inspect(documented -- served)}"
  end
end
