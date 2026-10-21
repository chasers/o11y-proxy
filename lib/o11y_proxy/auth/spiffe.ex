defmodule O11yProxy.Auth.SPIFFE do
  @moduledoc """
  Derives policy names from a SPIFFE ID claim (`spiffe://trust-domain/path`), for issuers
  whose `sub` names a workload rather than carrying a role claim of its own.

  The SPIFFE spec fixes the ID's syntax but says the path's meaning is "the
  responsibility of the administrator to define". So nothing here knows any issuer's
  layout. The config supplies it as a schema: a list of paths, each a pattern plus the
  policy names an ID matching it may hold.

    * A pattern such as `/aws/{account}/*/role/{role}` matches one segment per element:
      a literal matches itself, `*` any one segment, and `{name}` any one segment,
      captured under that name.
    * Its `policy_names`, such as `"{account}/{role}"`, are filled from the captures and
      tried in order; the first that names a policy wins.

  Policy names are one namespace, and a captured segment is chosen by whoever named the
  workload. So compiling refuses any schema in which two different templates could
  produce the same name — otherwise a role named `111122223333-admin` in one account
  could fill `{role}` and land on the policy `{account}-{role}` meant for another, or a
  Kubernetes service account named `sre` could land on the AWS role's policy. The one
  exception is the *same* template text under several patterns, which is how one issuer's
  alternative layouts (with and without a region, say) say they mean the same thing.

  Capture names stay strings throughout: they come from config, and atoms are never
  garbage collected. Pure: no token, no issuer, nothing booted.
  """

  @enforce_keys [:trust_domain, :paths]
  defstruct [:trust_domain, :paths]

  @typedoc "A compiled path pattern: one element per segment."
  @type pattern :: [{:literal, String.t()} | :any | {:capture, String.t()}]

  @typedoc """
  A compiled `policy_names` entry, as tokens: maximal runs of segment characters
  (`:segment`) and of anything else (`:other`), with each capture standing for one whole
  segment-character run. That shape is what makes overlap between templates decidable.
  """
  @type template :: [{:segment | :other, String.t()} | {:capture, String.t()}]

  @type t :: %__MODULE__{trust_domain: String.t(), paths: [{pattern(), [template()]}]}

  # The spec requires support for IDs up to 2048 bytes, and a signed claim is still no
  # reason to walk an unbounded string.
  @max_id_bytes 2048
  @max_trust_domain_bytes 255

  @doc """
  Compiles the `server.oidc.spiffe` block from its trust domain and a list of
  `{pattern, policy_names}`. Refuses anything that could never match, and any two
  templates that could produce the same name, so a mistake fails at boot, not as a
  `403` or as the wrong policy.
  """
  @spec compile(String.t(), [{String.t(), [String.t()]}]) :: {:ok, t()} | {:error, String.t()}
  def compile(trust_domain, paths) do
    with :ok <- check_trust_domain(trust_domain),
         {:ok, compiled} <- compile_paths(paths),
         :ok <- check_disjoint(paths, compiled) do
      {:ok, %__MODULE__{trust_domain: trust_domain, paths: compiled}}
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

  defp compile_paths([]), do: {:error, "paths needs at least one entry"}

  defp compile_paths(paths) do
    paths
    |> Enum.reduce_while({:ok, []}, fn {source, names}, {:ok, acc} ->
      case compile_entry(source, names) do
        {:ok, entry} -> {:cont, {:ok, [entry | acc]}}
        {:error, message} -> {:halt, {:error, "paths entry #{inspect(source)} #{message}"}}
      end
    end)
    |> case do
      {:ok, compiled} -> {:ok, Enum.reverse(compiled)}
      error -> error
    end
  end

  defp compile_entry(_source, []), do: {:error, "needs at least one policy_names entry"}

  defp compile_entry(source, names) do
    with {:ok, pattern} <- compile_path(source),
         {:ok, templates} <- compile_templates(names, captures(pattern), []) do
      {:ok, {pattern, templates}}
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

  defp compile_templates([], _captured, acc), do: {:ok, Enum.reverse(acc)}

  defp compile_templates([source | rest], captured, acc) do
    case compile_template(source, captured) do
      {:ok, template} -> compile_templates(rest, captured, [template | acc])
      {:error, message} -> {:error, "policy_names entry #{inspect(source)} #{message}"}
    end
  end

  defp compile_template("", _captured), do: {:error, "is empty"}

  defp compile_template(source, captured) do
    with true <- String.valid?(source) || {:error, "is not valid UTF-8"},
         {:ok, template} <- template_tokens(source, []),
         [] <- captures(template) -- captured,
         true <- separated?(template) do
      {:ok, template}
    else
      [name | _] ->
        {:error, "uses {#{name}}, which this pattern does not capture"}

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

  # -- overlap ---------------------------------------------------------------------------

  defp check_disjoint(paths, compiled) do
    sourced =
      for {{_pattern, sources}, {_compiled, templates}} <- Enum.zip(paths, compiled),
          pair <- Enum.zip(sources, templates),
          uniq: true,
          do: pair

    # `a < b` visits each pair of distinct template texts once; equal texts are the
    # allowed "same meaning in several layouts" case, and compile identically.
    clashes = for {a, ta} <- sourced, {b, tb} <- sourced, a < b and overlap?(ta, tb), do: {a, b}

    case clashes do
      [] ->
        :ok

      [{a, b} | _] ->
        {:error,
         "policy_names entries #{inspect(a)} and #{inspect(b)} can produce the same " <>
           "policy name from different IDs. Make them differ in their fixed text, e.g. " <>
           "with a prefix such as aws: or k8s:, or use the same template in both places " <>
           "if they mean the same thing"}
    end
  end

  # Whether two token lists can produce one string. A capture is exactly one whole
  # segment run, so it lines up with a capture or a segment literal, never with `:other`.
  defp overlap?([], []), do: true
  defp overlap?([token | a], [token | b]), do: overlap?(a, b)
  defp overlap?([{:capture, _} | a], [{:capture, _} | b]), do: overlap?(a, b)
  defp overlap?([{:capture, _} | a], [{:segment, _} | b]), do: overlap?(a, b)
  defp overlap?([{:segment, _} | a], [{:capture, _} | b]), do: overlap?(a, b)
  defp overlap?(_a, _b), do: false

  @doc """
  Whether some ID could ever be given `name` under `spiffe`. A policy no template can
  produce is unreachable, which config treats as a typo.
  """
  @spec produces?(t(), String.t()) :: boolean()
  def produces?(%__MODULE__{paths: paths}, name) do
    tokens = runs(name)
    Enum.any?(paths, fn {_pattern, templates} -> Enum.any?(templates, &overlap?(&1, tokens)) end)
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
  The policy names `id` yields under `spiffe`, in its path's `policy_names` order.

  `{:none, reason}` is an ID that yields no names — invalid, from another trust domain,
  or matching no pattern — which is a caller with no role, not a broken token.
  `{:error, _}` is two patterns matching one ID with different names: a config that is
  ambiguous for this ID, refused rather than resolved by picking one.
  """
  @spec roles(t(), String.t()) ::
          {:ok, [String.t(), ...]} | {:none, String.t()} | {:error, String.t()}
  def roles(%__MODULE__{trust_domain: domain, paths: paths}, id) do
    case parse(id) do
      {:ok, ^domain, segments} ->
        paths
        |> Enum.flat_map(&names_for(&1, segments))
        |> Enum.uniq()
        |> one_result()

      {:ok, other, _segments} ->
        {:none, "is in trust domain #{other}, not #{domain}"}

      :error ->
        {:none, "is not a valid SPIFFE ID"}
    end
  end

  defp names_for({pattern, templates}, segments) do
    for captures <- match(pattern, segments, %{}), do: fill_all(templates, captures)
  end

  defp one_result([]), do: {:none, "matches no configured path pattern"}
  defp one_result([names]), do: {:ok, names}

  defp one_result(_several),
    do: {:error, "matches more than one path pattern, with different policy names"}

  # Binding `segment` twice in one head is the equality check for a literal.
  defp match([], [], captures), do: [captures]

  defp match([{:literal, segment} | pattern], [segment | rest], acc),
    do: match(pattern, rest, acc)

  defp match([:any | pattern], [_segment | rest], acc), do: match(pattern, rest, acc)

  defp match([{:capture, name} | pattern], [segment | rest], acc),
    do: match(pattern, rest, Map.put(acc, name, segment))

  defp match(_pattern, _segments, _acc), do: []

  # Compiling checked every template's captures against its own pattern, so each fills.
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
