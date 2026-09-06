defmodule O11yProxyTest do
  use ExUnit.Case, async: true

  test "openapi_spec/0 returns the served spec, matching the served copy" do
    assert O11yProxy.openapi_spec() ==
             File.read!(Application.app_dir(:o11y_proxy, "priv/static/openapi.json"))
  end
end
