defmodule O11yProxy.Auth.SPIFFE do
  @moduledoc """
  Derives policy names from a SPIFFE ID claim (`spiffe://trust-domain/path`), for issuers
  whose `sub` names a workload rather than carrying a role claim of its own.

  The SPIFFE spec fixes the ID's syntax but says the path's meaning is "the
  responsibility of the administrator to define". So nothing here knows any issuer's
  layout. The config supplies it as a schema: a list of entries, each one or more
  patterns plus the policy names an ID matching any of them may hold.

    * A pattern such as `/aws/{account}/*/role/{role}` matches one segment per element:
      a literal matches itself, `*` any one segment, and `{name}` any one segment,
      captured under that name.
    * The entry's `policy_names`, such as `"{account}/{role}"`, are filled from the
      captures and tried in order; the first that names a policy wins.

  Listing several patterns in one entry is how alternative layouts of the same IDs —
  with and without a region, say — say they mean the same thing. Everything else is
  kept apart at compile time, so a mistake fails at boot rather than as a `403` or as
  the wrong policy:

    * patterns in one entry must have the same fixed segments in the same order, so an
      entry cannot quietly join two kinds of ID under one set of names;
    * no two patterns may match the same ID, so an ID has at most one reading;
    * no two different templates, in one entry or across entries, may produce the same
      name. A captured segment is chosen by whoever named the workload, so otherwise a
      role named `111122223333-admin` could fill `{role}` and land on the policy
      `{account}-{role}` meant for one account, or a Kubernetes service account named
      `sre` could land on the AWS role's policy. Capture names are not consulted: they
      mean nothing to the proxy, so they cannot be what keeps two layouts apart.

  Capture names stay strings throughout: they come from config, and atoms are never
  garbage collected. Pure: no token, no issuer, nothing booted.
  """

  @enforce_keys [:trust_domain, :entries]
  defstruct [:trust_domain, :entries]

  @typedoc "A compiled path pattern: one element per segment."
  @type pattern :: [{:literal, String.t()} | :any | {:capture, String.t()}]

  @typedoc """
  A compiled `policy_names` entry, as tokens: maximal runs of segment characters
  (`:segment`) and of anything else (`:other`), with each capture standing for one whole
  segment-character run. That shape is what makes overlap between templates decidable.
  """
  @type template :: [{:segment | :other, String.t()} | {:capture, String.t()}]

  @type t :: %__MODULE__{trust_domain: String.t(), entries: [{[pattern()], [template()]}]}

  # The spec requires support for IDs up to 2048 bytes, and a signed claim is still no
  # reason to walk an unbounded string.
  @max_id_bytes 2048
  @max_trust_domain_bytes 255

  @doc """
  Compiles the `server.oidc.spiffe` block from its trust domain and a list of
  `{patterns, policy_names}` entries. Refuses anything that could never match, any two
  patterns that could match one ID, and any two templates that could produce one name.
  """
  @spec compile(String.t(), [{[String.t()], [String.t()]}]) ::
          {:ok, t()} | {:error, String.t()}
  def compile(trust_domain, entries) do
    with :ok <- check_trust_domain(trust_domain),
         {:ok, compiled} <- compile_entries(entries),
         :ok <- check_patterns_disjoint(entries, compiled),
         :ok <- check_templates_disjoint(entries, compiled) do
      {:ok, %__MODULE__{trust_domain: trust_domain, entries: compiled}}
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

  defp compile_entries([]), do: {:error, "paths needs at least one entry"}

  defp compile_entries(entries) do
    entries
    |> Enum.with_index()
    |> map_ok(fn {{patterns, names}, index} ->
      with {:error, message} <- compile_entry(patterns, names),
           do: {:error, "paths[#{index}] #{message}"}
    end)
  end

  defp compile_entry([], _names), do: {:error, "needs at least one pattern"}
  defp compile_entry(_patterns, []), do: {:error, "needs at least one policy_names entry"}

  defp compile_entry(sources, names) do
    with {:ok, patterns} <- map_ok(sources, &compile_path/1),
         {:ok, templates} <- map_ok(names, &compile_template/1),
         :ok <- check_same_kind(sources, patterns),
         :ok <- check_filled(sources, patterns, names, templates) do
      {:ok, {patterns, templates}}
    end
  end

  # The patterns in one entry share its names unchecked, so they must be layouts of one
  # kind of ID. What an ID means is the operator's, but the fixed segments are the part
  # of a layout that says which kind it is — aws/role against k8s/sa — so they must
  # agree. Without this, grouping would be a way around the template collision check.
  defp check_same_kind([first | sources], [pattern | patterns]) do
    kind = literals(pattern)

    case Enum.find(Enum.zip(sources, patterns), fn {_source, p} -> literals(p) != kind end) do
      nil ->
        :ok

      {other, _pattern} ->
        {:error,
         "groups patterns #{inspect(first)} and #{inspect(other)}, whose fixed segments " <>
           "differ, so they are not layouts of the same IDs. Give each its own entry, " <>
           "with policy_names that differ in fixed text"}
    end
  end

  defp literals(pattern), do: for({:literal, segment} <- pattern, do: segment)

  # Whichever of an entry's patterns matches, every template has to be fillable from it.
  defp check_filled(sources, patterns, names, templates) do
    missing =
      for {source, pattern} <- Enum.zip(sources, patterns),
          {name, template} <- Enum.zip(names, templates),
          capture <- captures(template) -- captures(pattern),
          do: {name, capture, source}

    case missing do
      [] ->
        :ok

      [{name, capture, source} | _] ->
        {:error,
         "policy_names entry #{inspect(name)} uses {#{capture}}, which pattern " <>
           "#{inspect(source)} does not capture"}
    end
  end

  # Config-sized lists only, so plain recursion is fine.
  defp map_ok([], _fun), do: {:ok, []}

  defp map_ok([item | rest], fun) do
    with {:ok, value} <- fun.(item),
         {:ok, values} <- map_ok(rest, fun),
         do: {:ok, [value | values]}
  end

  # -- path patterns ---------------------------------------------------------------------

  defp compile_path(source) do
    with {:error, message} <- pattern(source),
         do: {:error, "pattern #{inspect(source)} #{message}"}
  end

  defp pattern("/" <> path) do
    with {:ok, pattern} <- compile_segments(String.split(path, "/"), []) do
      case captures(pattern) -- Enum.uniq(captures(pattern)) do
        [] -> {:ok, pattern}
        [name | _] -> {:error, "captures {#{name}} more than once"}
      end
    end
  end

  defp pattern(_source), do: {:error, "must start with /"}

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

  # Two patterns can match one ID when they have as many segments and agree on every
  # pair of literals; `*` and `{name}` match any literal.
  defp patterns_overlap?([], []), do: true
  defp patterns_overlap?([{:literal, s} | a], [{:literal, s} | b]), do: patterns_overlap?(a, b)
  defp patterns_overlap?([{:literal, _} | _], [{:literal, _} | _]), do: false
  defp patterns_overlap?([_ | a], [_ | b]), do: patterns_overlap?(a, b)
  defp patterns_overlap?(_a, _b), do: false

  defp check_patterns_disjoint(entries, compiled) do
    sourced =
      for {{{sources, _names}, {patterns, _templates}}, index} <-
            Enum.with_index(Enum.zip(entries, compiled)),
          {source, pattern} <- Enum.zip(sources, patterns),
          do: {{index, source}, pattern}

    case first_clash(sourced, &patterns_overlap?/2) do
      nil ->
        :ok

      {{ia, a}, {ib, b}} ->
        {:error,
         "pattern #{inspect(a)} in paths[#{ia}] and #{inspect(b)} in paths[#{ib}] can " <>
           "both match one ID, which would then have two readings. Make them differ in a " <>
           "fixed segment, or keep one"}
    end
  end

  # The first pair, in list order, whose compiled forms `clash?` says cannot coexist.
  # Quadratic, but over config-sized lists, and it reports the earliest pair the operator
  # wrote rather than an arbitrary one.
  defp first_clash(sourced, clash?) do
    pairs =
      for {a, next} <- Enum.with_index(sourced, 1), b <- Enum.drop(sourced, next), do: {a, b}

    Enum.find_value(pairs, fn {{a, ca}, {b, cb}} -> if clash?.(ca, cb), do: {a, b} end)
  end

  # -- policy_names templates ------------------------------------------------------------

  defp compile_template(source) do
    with {:error, message} <- template(source),
         do: {:error, "policy_names entry #{inspect(source)} #{message}"}
  end

  defp template(""), do: {:error, "is empty"}

  defp template(source) do
    with true <- String.valid?(source) || {:error, "is not valid UTF-8"},
         {:ok, template} <- template_tokens(source, []),
         true <- separated?(template) do
      {:ok, template}
    else
      false ->
        {:error,
         "puts a {name} next to a letter, digit, ., - or _, or next to another {name}. " <>
           "Those can be part of the captured segment, so two different IDs could fill " <>
           "it to the same policy name; separate each {name} with a character no " <>
           "segment can hold, such as / or :"}

      {:error, _} = error ->
        error
    end
  end

  defp template_tokens(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp template_tokens("{" <> rest, acc) do
    case :binary.split(rest, "}") do
      [name, rest] ->
        if name?(name),
          do: template_tokens(rest, [{:capture, name} | acc]),
          else: {:error, "has {#{name}}, which is not a valid {name}"}

      [_unclosed] ->
        {:error, "has a { with no closing }"}
    end
  end

  defp template_tokens("}" <> _rest, _acc), do: {:error, "has a } with no opening {"}

  defp template_tokens(text, acc) do
    {literal, rest} =
      case :binary.match(text, ["{", "}"]) do
        :nomatch -> {text, ""}
        {at, _length} -> :erlang.split_binary(text, at)
      end

    template_tokens(rest, Enum.reverse(runs(literal), acc))
  end

  # Splits text into maximal runs of segment characters and of everything else.
  defp runs(text) do
    text
    |> String.codepoints()
    |> Enum.chunk_by(&segment_chars?/1)
    |> Enum.map(fn chars ->
      run = Enum.join(chars)
      if segment_chars?(run), do: {:segment, run}, else: {:other, run}
    end)
  end

  # Text runs are maximal by construction, so two segment-like tokens in a row can only
  # be a capture touching segment text, or two captures touching.
  defp separated?([]), do: true
  defp separated?([_last]), do: true
  defp separated?([{:other, _}, next | rest]), do: separated?([next | rest])
  defp separated?([_segment_like, {:other, _} = next | rest]), do: separated?([next | rest])
  defp separated?(_touching), do: false

  defp check_templates_disjoint(entries, compiled) do
    # Keyed by entry index as well as text: the same text in two entries is two layouts
    # sharing a namespace, which is exactly what has to be refused.
    sourced =
      for {{{_patterns, names}, {_compiled, templates}}, index} <-
            Enum.with_index(Enum.zip(entries, compiled)),
          {name, template} <- Enum.zip(names, templates),
          uniq: true,
          do: {{index, name}, template}

    case first_clash(sourced, &overlap?/2) do
      nil ->
        :ok

      {{ia, a}, {ib, b}} ->
        {:error,
         "policy_names #{inspect(a)} in paths[#{ia}] and #{inspect(b)} in paths[#{ib}] " <>
           "can produce the same policy name from different IDs. Make them differ in " <>
           "their fixed text, e.g. with a prefix such as aws: or k8s:" <> regroup_hint(ia, ib)}
    end
  end

  # Both in one entry, the IDs already share a list, so regrouping is no fix.
  defp regroup_hint(index, index), do: ""

  defp regroup_hint(_ia, _ib),
    do: ". If the IDs mean the same thing, list their patterns under one entry instead"

  # Whether two token lists can produce one string. A capture is exactly one whole
  # segment run, so it lines up with a capture or a segment literal, never with `:other`
  # — and never with `.` or `..`, which no SPIFFE segment can be.
  defp overlap?([], []), do: true
  defp overlap?([token | a], [token | b]), do: overlap?(a, b)
  defp overlap?([{:capture, _} | _], [{:segment, dots} | _]) when dots in [".", ".."], do: false
  defp overlap?([{:segment, dots} | _], [{:capture, _} | _]) when dots in [".", ".."], do: false
  defp overlap?([{:capture, _} | a], [{:capture, _} | b]), do: overlap?(a, b)
  defp overlap?([{:capture, _} | a], [{:segment, _} | b]), do: overlap?(a, b)
  defp overlap?([{:segment, _} | a], [{:capture, _} | b]), do: overlap?(a, b)
  defp overlap?(_a, _b), do: false

  @doc """
  Whether some ID could ever be given `name` under `spiffe`. A policy no template can
  produce is unreachable, which config treats as a typo.
  """
  @spec produces?(t(), String.t()) :: boolean()
  def produces?(%__MODULE__{entries: entries}, name) do
    tokens = runs(name)

    Enum.any?(entries, fn {_patterns, templates} ->
      Enum.any?(templates, &overlap?(&1, tokens))
    end)
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
  The policy names `id` yields under `spiffe`, in its entry's `policy_names` order.

  `{:none, reason}` is an ID that yields no names — invalid, from another trust domain,
  or matching no pattern — which is a caller with no role, not a broken token. Compiling
  refused overlapping patterns, so an ID matches at most one and has one reading.
  """
  @spec roles(t(), String.t()) :: {:ok, [String.t(), ...]} | {:none, String.t()}
  def roles(%__MODULE__{trust_domain: domain, entries: entries}, id) do
    case parse(id) do
      {:ok, ^domain, segments} ->
        case Enum.find_value(entries, &names_for(&1, segments)) do
          nil -> {:none, "matches no configured path pattern"}
          names -> {:ok, names}
        end

      {:ok, other, _segments} ->
        {:none, "is in trust domain #{other}, not #{domain}"}

      :error ->
        {:none, "is not a valid SPIFFE ID"}
    end
  end

  defp names_for({patterns, templates}, segments) do
    Enum.find_value(patterns, fn pattern ->
      with %{} = captures <- match(pattern, segments, %{}), do: fill_all(templates, captures)
    end)
  end

  # Binding `segment` twice in one head is the equality check for a literal.
  defp match([], [], captures), do: captures

  defp match([{:literal, segment} | pattern], [segment | rest], acc),
    do: match(pattern, rest, acc)

  defp match([:any | pattern], [_segment | rest], acc), do: match(pattern, rest, acc)

  defp match([{:capture, name} | pattern], [segment | rest], acc),
    do: match(pattern, rest, Map.put(acc, name, segment))

  defp match(_pattern, _segments, _acc), do: nil

  # Compiling checked every template against every pattern in its entry, so each fills.
  defp fill_all(templates, captures) do
    templates
    |> Enum.map(fn template ->
      Enum.map_join(template, fn
        {:capture, name} -> Map.fetch!(captures, name)
        {_kind, text} -> text
      end)
    end)
    |> Enum.uniq()
  end

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

  defp segment_chars?(""), do: false
  defp segment_chars?(text), do: all_segment_chars?(text)

  defp all_segment_chars?(<<>>), do: true

  defp all_segment_chars?(<<c, rest::binary>>)
       when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c in [?., ?-, ?_],
       do: all_segment_chars?(rest)

  defp all_segment_chars?(_other), do: false

  defp name?(<<?_, rest::binary>>), do: name_chars?(rest)
  defp name?(<<c, rest::binary>>) when c in ?a..?z, do: name_chars?(rest)
  defp name?(_name), do: false

  defp name_chars?(<<>>), do: true
  defp name_chars?(<<?_, rest::binary>>), do: name_chars?(rest)
  defp name_chars?(<<c, rest::binary>>) when c in ?a..?z or c in ?0..?9, do: name_chars?(rest)
  defp name_chars?(_other), do: false
end
