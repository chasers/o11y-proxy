defmodule O11yProxy.BackendTest do
  use ExUnit.Case, async: true

  alias O11yProxy.{Backend, ResponseError}

  describe "credential_failure?/1" do
    test "is true only for a credential kind with a message" do
      for kind <- Backend.credential_failure_kinds() do
        assert Backend.credential_failure?({kind, "detail"})
        refute Backend.credential_failure?({kind, :not_a_message})
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
  end
end
