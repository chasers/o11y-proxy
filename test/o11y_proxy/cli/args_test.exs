defmodule O11yProxy.CLI.ArgsTest do
  use ExUnit.Case, async: true

  alias O11yProxy.CLI.Args
  alias O11yProxy.Query.Filter

  describe "commands" do
    test "no arguments is the server, so an existing systemd unit keeps working" do
      assert {:ok, %{command: :serve, request: %{}}} = Args.parse([])
      assert {:ok, %{command: :serve}} = Args.parse(["serve"])
    end

    test "serve rejects trailing arguments rather than ignoring them" do
      assert {:error, message} = Args.parse(["serve", "--port", "4001"])
      assert message =~ "serve takes no arguments"
    end

    test "sources, health and schema" do
      assert {:ok, %{command: :sources, request: %{}}} = Args.parse(["sources"])
      assert {:ok, %{command: :health, request: %{}}} = Args.parse(["health"])

      assert {:ok, %{command: :schema, request: %{"source" => "app_logs"}}} =
               Args.parse(["schema", "app_logs"])
    end

    test "schema without a source name is a usage error" do
      assert {:error, message} = Args.parse(["schema"])
      assert message =~ "schema needs a source name"
    end

    test "an unknown command points at --help instead of crashing" do
      assert {:error, message} = Args.parse(["quesry"])
      assert message =~ "unknown command: quesry"
      assert message =~ "--help"
    end

    # If control ever reached Kernel.CLI it would swallow these, so we
    # own them. -h/-v included, since those are the ones Kernel.CLI takes for itself.
    test "--help and --version are ours, in either form and anywhere in argv" do
      assert {:print, help} = Args.parse(["--help"])
      assert help =~ "USAGE"
      assert {:print, ^help} = Args.parse(["-h"])
      assert {:print, ^help} = Args.parse(["query", "--source", "x", "--help"])

      assert {:print, version} = Args.parse(["--version"])
      assert version =~ "o11y-proxy"
      assert {:print, ^version} = Args.parse(["-v"])
    end
  end

  describe "query" do
    test "builds the same request map POST /v1/query receives" do
      assert {:ok, %{command: :query, request: request}} =
               Args.parse(~w(query --source app_logs --signal logs --from now-1h --to now))

      assert request == %{
               "sources" => ["app_logs"],
               "signal" => "logs",
               "from" => "now-1h",
               "to" => "now",
               "filters" => []
             }
    end

    test "carries the optional flags through under their API names" do
      assert {:ok, %{request: request, pretty: true}} =
               Args.parse(~w(
                 query --source s --signal logs --from now-1h --to now
                 --mode full --limit 5 --order asc --cursor abc --raw SELECT --pretty
               ))

      assert request["mode"] == "full"
      assert request["limit"] == 5
      assert request["order"] == "asc"
      assert request["cursor"] == "abc"
      assert request["raw"] == "SELECT"
    end

    test "omitted options are absent, not null — the core owns their defaults" do
      assert {:ok, %{request: request}} =
               Args.parse(~w(query --source s --signal logs --from now-1h --to now))

      refute Map.has_key?(request, "mode")
      refute Map.has_key?(request, "limit")
      refute Map.has_key?(request, "cursor")
    end

    test "each required flag is named when it's missing" do
      for {argv, missing} <- [
            {~w(query --signal logs --from a --to b), "--source"},
            {~w(query --source s --from a --to b), "--signal"},
            {~w(query --source s --signal logs --to b), "--from"},
            {~w(query --source s --signal logs --from a), "--to"}
          ] do
        assert {:error, message} = Args.parse(argv)
        assert message =~ missing
      end
    end

    test "an unknown flag is a usage error, not a silently dropped argument" do
      assert {:error, message} =
               Args.parse(~w(query --source s --signal logs --from a --to b --sources x))

      assert message =~ "unknown option --sources"
    end

    test "a non-integer --limit is rejected" do
      assert {:error, message} =
               Args.parse(~w(query --source s --signal logs --from a --to b --limit lots))

      assert message =~ "--limit"
    end

    test "a bare positional argument is a usage error" do
      assert {:error, message} =
               Args.parse(~w(query app_logs --signal logs --from a --to b))

      assert message =~ "unexpected argument app_logs"
    end

    test "--filter repeats, in order" do
      assert {:ok, %{request: %{"filters" => filters}}} =
               Args.parse(~w(
                 query --source s --signal logs --from a --to b
                 --filter severity=error --filter service=api
               ))

      assert filters == [
               %{"field" => "severity", "op" => "eq", "value" => "error"},
               %{"field" => "service", "op" => "eq", "value" => "api"}
             ]
    end

    test "a bad --filter fails the whole command" do
      assert {:error, message} =
               Args.parse(~w(query --source s --signal logs --from a --to b --filter nope))

      assert message =~ "has no operator"
    end
  end

  describe "context" do
    test "each entry form maps to the field the core classifies on" do
      assert {:ok, %{command: :context, request: %{"trace_id" => "abc"}}} =
               Args.parse(~w(context --trace-id abc))

      assert {:ok, %{request: %{"error_id" => "xyz"}}} = Args.parse(~w(context --error-id xyz))

      assert {:ok, %{request: request}} =
               Args.parse(~w(context --service checkout --from now-1h --to now))

      assert request == %{"service" => "checkout", "from" => "now-1h", "to" => "now"}
    end

    # "Exactly one of" belongs to O11yProxy.Context.classify/1. Duplicating it here would
    # be a second definition to keep in sync, so the CLI passes both through and lets the
    # core produce its own :ambiguous_request error.
    test "passes an ambiguous request through for the core to reject" do
      assert {:ok, %{request: request}} =
               Args.parse(~w(context --trace-id abc --error-id xyz))

      assert request == %{"trace_id" => "abc", "error_id" => "xyz"}
    end

    test "an unknown flag is a usage error" do
      assert {:error, message} = Args.parse(~w(context --trace abc))
      assert message =~ "unknown option --trace"
    end
  end

  describe "parse_filter/1 operator matching" do
    test "every compact form maps to its canonical operator" do
      assert Args.parse_filter("severity=error") ==
               {:ok, %{"field" => "severity", "op" => "eq", "value" => "error"}}

      assert Args.parse_filter("service!=cron") ==
               {:ok, %{"field" => "service", "op" => "neq", "value" => "cron"}}

      assert Args.parse_filter("body~timeout") ==
               {:ok, %{"field" => "body", "op" => "contains", "value" => "timeout"}}

      assert Args.parse_filter("body=~^GET") ==
               {:ok, %{"field" => "body", "op" => "regex", "value" => "^GET"}}

      assert Args.parse_filter("trace_id?") ==
               {:ok, %{"field" => "trace_id", "op" => "exists", "value" => true}}
    end

    # The whole reason for longest-token-first matching: each of these contains an `=`.
    test "!=, >=, <= and =~ are not shadowed by =" do
      assert {:ok, %{"op" => "neq", "field" => "service", "value" => "cron"}} =
               Args.parse_filter("service!=cron")

      assert {:ok, %{"op" => "gte", "field" => "d", "value" => 1000}} =
               Args.parse_filter("d>=1000")

      assert {:ok, %{"op" => "lte", "field" => "d", "value" => 50}} = Args.parse_filter("d<=50")

      assert {:ok, %{"op" => "regex", "field" => "body", "value" => "a=b"}} =
               Args.parse_filter("body=~a=b")
    end

    test "matches the earliest operator, so later ones stay in the value" do
      assert Args.parse_filter("body~a>=b") ==
               {:ok, %{"field" => "body", "op" => "contains", "value" => "a>=b"}}

      assert Args.parse_filter("body=a!=b") ==
               {:ok, %{"field" => "body", "op" => "eq", "value" => "a!=b"}}
    end

    test "a ? inside a value is part of the value, not the exists operator" do
      assert Args.parse_filter("body~why?") ==
               {:ok, %{"field" => "body", "op" => "contains", "value" => "why?"}}
    end

    test "values are typed the way they would arrive over JSON" do
      assert {:ok, %{"value" => 1000}} = Args.parse_filter("d>=1000")
      assert {:ok, %{"value" => 1.5}} = Args.parse_filter("d>=1.5")
      assert {:ok, %{"value" => true}} = Args.parse_filter("ok=true")
      assert {:ok, %{"value" => false}} = Args.parse_filter("ok=false")
      assert {:ok, %{"value" => "500ms"}} = Args.parse_filter("d=500ms")
    end

    test "double quotes keep a numeric-looking value a string" do
      assert {:ok, %{"value" => "500"}} = Args.parse_filter(~s(status="500"))
      assert {:ok, %{"value" => "true"}} = Args.parse_filter(~s(flag="true"))
    end

    test "malformed filters name what was wrong" do
      assert {:error, message} = Args.parse_filter("severity")
      assert message =~ "has no operator"

      assert {:error, message} = Args.parse_filter("=error")
      assert message =~ "no field before the operator"

      assert {:error, message} = Args.parse_filter("?")
      assert message =~ "no field name"
    end

    # `in` is the one canonical operator with no shorthand — see the module doc. The help
    # has to say so, or someone hunts for a form that doesn't exist.
    test "help documents that in has no compact form" do
      assert Args.help_text() =~ "`in` operator has no compact form"
    end
  end

  test "every filter map parses as a canonical filter" do
    for raw <- ["severity=error", "s!=c", "d>=1", "d<=1", "b~x", "b=~x", "t?"] do
      assert {:ok, map} = Args.parse_filter(raw)
      assert {:ok, _} = Filter.parse(map)
    end
  end
end
