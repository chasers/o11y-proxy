defmodule O11yProxy.Auth.SPIFFE do
  @moduledoc """
  Derives role names from a SPIFFE ID claim (`spiffe://trust-domain/path`), for issuers
  whose `sub` names a workload rather than carrying a role claim of its own.

  The SPIFFE spec fixes the ID's syntax but says the path's meaning is "the
  responsibility of the administrator to define". So nothing here knows any issuer's
  layout. The config supplies it as a schema, in two parts:

    * `paths` — patterns such as `/aws/{account}/*/role/{role}`. A literal segment
      matches itself, `*` matches any one segment, and `{name}` captures one segment
      under that name. An issuer that emits several layouts gets one pattern each.
    * `policy_names` — templates such as `"{account}/{role}"`, filled from the captures
      and tried in order; the first that names a policy wins. A template using a name
      the matched pattern did not capture is skipped, so a layout without a segment
      falls through to the templates that do not need it.

  Capture names stay strings throughout: they come from config, and atoms are never
  garbage collected. Pure: no token, no issuer, nothing booted.
  """

  @enforce_keys [:trust_domain, :patterns, :policy_names]
  defstruct [:trust_domain, :patterns, :policy_names]

  @typedoc "A compiled path pattern: one element per segment."
  @type pattern :: [{:literal, String.t()} | :any | {:capture, String.t()}]

  @typedoc "A compiled `policy_names` entry: literal text and captures, in order."
  @type template :: [String.t() | {:capture, String.t()}]

  @type t :: %__MODULE__{
          trust_domain: String.t(),
          patterns: [pattern()],
          policy_names: [template()]
        }

  # The spec requires support for IDs up to 2048 bytes, and a signed claim is still no
  # reason to walk an unbounded string.
  @max_id_bytes 2048
  @max_trust_domain_bytes 255

  @doc """
  Compiles the `server.oidc.spiffe` block. Fails with a message on anything that could
  never match: a bad trust domain or pattern, a template needing a capture no pattern
  makes, or a pattern that fills no template. A typo fails at boot, not as a `403`.
  """
  @spec compile(String.t(), [String.t()], [String.t()]) :: {:ok, t()} | {:error, String.t()}
  def compile(trust_domain, paths, policy_names) do
    with :ok <- check_trust_domain(trust_domain),
         {:ok, patterns} <- compile_all(paths, "paths", &compile_path/1),
         {:ok, templates} <- compile_all(policy_names, "policy_names", &compile_template/1),
         :ok <- check_coverage(paths, patterns, policy_names, templates) do
      {:ok, %__MODULE__{trust_domain: trust_domain, patterns: patterns, policy_names: templates}}
    end
  end

  defp check_trust_domain(domain) do
    if trust_domain?(domain),
      do: :ok,
      else:
        {:error,
         "trust_domain #{inspect(domain)} is not a SPIFFE trust domain: lowercase " <>
           "letters, digits, dots, dashes and underscores only, no scheme or path"}
  end

  defp compile_all([], key, _compile), do: {:error, "#{key} needs at least one entry"}

  defp compile_all(entries, key, compile) do
    entries
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case compile.(entry) do
        {:ok, compiled} -> {:cont, {:ok, [compiled | acc]}}
        {:error, message} -> {:halt, {:error, "#{key} entry #{inspect(entry)} #{message}"}}
      end
    end)
    |> case do
      {:ok, compiled} -> {:ok, Enum.reverse(compiled)}
      error -> error
    end
  end

  # -- path patterns ---------------------------------------------------------------------

  defp compile_path("/" <> path) do
    with {:ok, pattern} <- compile_segments(String.split(path, "/"), []) do
      case captures(pattern) -- Enum.uniq(captures(pattern)) do
        [] -> {:ok, pattern}
        [name | _] -> {:error, "captures {#{name}} more than once"}
      end
    end
  end

  defp compile_path(_path), do: {:error, "must start with /"}

  defp compile_segments([], acc), do: {:ok, Enum.reverse(acc)}
  defp compile_segments(["*" | rest], acc), do: compile_segments(rest, [:any | acc])

  defp compile_segments(["{" <> _ = segment | rest], acc) do
    case placeholder(segment) do
      {:ok, name} -> compile_segments(rest, [{:capture, name} | acc])
      :error -> {:error, "has #{inspect(segment)}, which is not a valid {name}"}
    end
  end

  defp compile_segments([segment | rest], acc) do
    if segment?(segment),
      do: compile_segments(rest, [{:literal, segment} | acc]),
      else: {:error, "has #{inspect(segment)}, which no SPIFFE ID path segment can be"}
  end

  defp placeholder("{" <> rest) do
    case String.split_at(rest, -1) do
      {name, "}"} -> if name?(name), do: {:ok, name}, else: :error
      _ -> :error
    end
  end

  defp captures(pattern), do: for({:capture, name} <- pattern, do: name)

  # -- policy_names templates ------------------------------------------------------------

  defp compile_template(""), do: {:error, "is empty"}
  defp compile_template(template), do: template_parts(template, [])

  defp template_parts(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp template_parts(<<"{", rest::binary>>, acc) do
    case :binary.split(rest, "}") do
      [name, rest] ->
        if name?(name),
          do: template_parts(rest, [{:capture, name} | acc]),
          else: {:error, "has {#{name}}, which is not a valid {name}"}

      [_unclosed] ->
        {:error, "has a { with no closing }"}
    end
  end

  defp template_parts(<<"}", _rest::binary>>, _acc), do: {:error, "has a } with no opening {"}

  defp template_parts(<<c::utf8, rest::binary>>, [text | acc]) when is_binary(text),
    do: template_parts(rest, [text <> <<c::utf8>> | acc])

  defp template_parts(<<c::utf8, rest::binary>>, acc),
    do: template_parts(rest, [<<c::utf8>> | acc])

  defp template_parts(_invalid, _acc), do: {:error, "is not valid UTF-8"}

  defp needs(template), do: for({:capture, name} <- template, do: name)

  # A template can only be filled by a pattern capturing every name it uses.
  defp fills?(pattern, template), do: needs(template) -- captures(pattern) == []

  defp check_coverage(paths, patterns, names, templates) do
    unfillable =
      for {name, template} <- Enum.zip(names, templates),
          not Enum.any?(patterns, &fills?(&1, template)),
          do: name

    useless =
      for {path, pattern} <- Enum.zip(paths, patterns),
          not Enum.any?(templates, &fills?(pattern, &1)),
          do: path

    case {unfillable, useless} do
      {[], []} ->
        :ok

      {[name | _], _} ->
        {:error,
         "policy_names entry #{inspect(name)} uses a {name} that no path captures, so it " <>
           "can never be filled"}

      {[], [path | _]} ->
        {:error,
         "paths entry #{inspect(path)} fills no policy_names entry, since each uses a " <>
           "{name} it does not capture, so an ID matching it can never get a policy"}
    end
  end

  # -- IDs -------------------------------------------------------------------------------

  @doc """
  Parses a SPIFFE ID strictly, by the spec: no port, userinfo, query, fragment or
  percent-encoding, and no empty, `.` or `..` path segment. Anything else is `:error` —
  an ID that is almost valid is not one.

  One rule is stricter than the spec's letter: the scheme and trust domain must already
  be lowercase, as go-spiffe also requires, rather than being folded. Folding would make
  two spellings of one ID both valid, and the policy match is on exact strings.
  """
  @spec parse(term()) :: {:ok, String.t(), [String.t()]} | :error
  def parse("spiffe://" <> rest = id) when byte_size(id) <= @max_id_bytes do
    with [domain | segments] <- String.split(rest, "/"),
         true <- trust_domain?(domain),
         true <- Enum.all?(segments, &segment?/1) do
      {:ok, domain, segments}
    else
      _ -> :error
    end
  end

  def parse(_id), do: :error

  @doc """
  The policy names `id` yields under `spiffe`, in `policy_names` order.

  `{:none, reason}` is an ID that yields no role — invalid, from another trust domain, or
  matching no pattern — which is a caller with no role, not a broken token. `{:error, _}`
  is two patterns matching one ID with different results: a config that is ambiguous
  for this ID, refused rather than resolved by picking one.
  """
  @spec roles(t(), term()) ::
          {:ok, [String.t(), ...]} | {:none, String.t()} | {:error, String.t()}
  def roles(%__MODULE__{trust_domain: domain} = spiffe, id) do
    case parse(id) do
      {:ok, ^domain, segments} ->
        spiffe.patterns
        |> Enum.flat_map(&match(&1, segments, %{}))
        |> Enum.map(&fill_all(spiffe.policy_names, &1))
        |> Enum.uniq()
        |> one_result()

      {:ok, other, _segments} ->
        {:none, "is in trust domain #{other}, not #{domain}"}

      :error ->
        {:none, "is not a valid SPIFFE ID"}
    end
  end

  # Compared on the names produced, not the captures: two layouts that agree on every
  # policy name are not ambiguous in any way that matters.
  defp one_result([]), do: {:none, "matches no configured path pattern"}
  defp one_result([names]), do: {:ok, names}

  defp one_result(_several),
    do: {:error, "matches more than one path pattern, with different results"}

  # Binding `segment` twice in one head is the equality check for a literal.
  defp match([], [], captures), do: [captures]

  defp match([{:literal, segment} | pattern], [segment | rest], acc),
    do: match(pattern, rest, acc)

  defp match([:any | pattern], [_segment | rest], acc), do: match(pattern, rest, acc)

  defp match([{:capture, name} | pattern], [segment | rest], acc),
    do: match(pattern, rest, Map.put(acc, name, segment))

  defp match(_pattern, _segments, _acc), do: []

  defp fill_all(templates, captures) do
    templates |> Enum.flat_map(&fill(&1, captures, [])) |> Enum.uniq()
  end

  defp fill([], _captures, acc), do: [acc |> Enum.reverse() |> IO.iodata_to_binary()]

  defp fill([{:capture, name} | rest], captures, acc) do
    case captures do
      %{^name => value} -> fill(rest, captures, [value | acc])
      _missing -> []
    end
  end

  defp fill([text | rest], captures, acc), do: fill(rest, captures, [text | acc])

  # -- character classes -----------------------------------------------------------------

  defp trust_domain?(domain) when byte_size(domain) in 1..@max_trust_domain_bytes,
    do: domain_chars?(domain)

  defp trust_domain?(_domain), do: false

  defp domain_chars?(<<>>), do: true

  defp domain_chars?(<<c, rest::binary>>)
       when c in ?a..?z or c in ?0..?9 or c in [?., ?-, ?_],
       do: domain_chars?(rest)

  defp domain_chars?(_other), do: false

  defp segment?(segment) when segment in ["", ".", ".."], do: false
  defp segment?(segment), do: segment_chars?(segment)

  defp segment_chars?(<<>>), do: true

  defp segment_chars?(<<c, rest::binary>>)
       when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c in [?., ?-, ?_],
       do: segment_chars?(rest)

  defp segment_chars?(_other), do: false

  defp name?(<<?_, rest::binary>>), do: name_chars?(rest)
  defp name?(<<c, rest::binary>>) when c in ?a..?z, do: name_chars?(rest)
  defp name?(_name), do: false

  defp name_chars?(<<>>), do: true
  defp name_chars?(<<?_, rest::binary>>), do: name_chars?(rest)
  defp name_chars?(<<c, rest::binary>>) when c in ?a..?z or c in ?0..?9, do: name_chars?(rest)
  defp name_chars?(_other), do: false
end
