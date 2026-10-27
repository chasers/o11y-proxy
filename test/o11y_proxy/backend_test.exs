defmodule O11yProxy.BackendTest do
  use ExUnit.Case, async: true

  alias O11yProxy.{Backend, ResponseError}

  describe "credential_failure?/1" do
    test "is true for a credential kind, whatever its detail" do
      for kind <- Backend.credential_failure_kinds() do
        assert Backend.credential_failure?({kind, "detail"})
        assert Backend.credential_failure?({kind, :enoent})
      end

      refute Backend.credential_failure?({:victoriametrics_unreachable, "detail"})
      refute Backend.credential_failure?(:timeout)
    end

    # The breaker exemption and the caller's message are keyed on the same kinds; a kind
    # added here without a ResponseError shape would reach callers as an inspected term.
    test "every kind has its own caller-facing message" do
      for kind <- Backend.credential_failure_kinds() do
        %{code: code, message: message} = ResponseError.build("src", {kind, "the detail"})

        assert code in ["unreachable", "internal"]
        assert message =~ "the detail"
        refute message =~ inspect(kind)
      end
    end

    # /healthz renders every source's error this way, so one odd detail must not raise.
    test "a detail that is not a string is inspected, not interpolated" do
      for kind <- Backend.credential_failure_kinds() do
        assert %{message: message} = ResponseError.build("src", {kind, %{status: 401}})
        assert message =~ "%{status: 401}"
      end
    end
  end
end
