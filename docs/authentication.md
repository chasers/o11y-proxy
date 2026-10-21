# Authentication and access control

This page covers who may call o11y-proxy, and what each caller may query.

- Auth is off by default.
- Turn it on before you expose the server beyond your own machine.
- OIDC mode works with any OpenID Connect issuer.
- Policies decide which sources a caller sees.
- Policies can also force filters onto every query.

A working config is in [`examples/oidc-rbac/o11y.yaml`](../examples/oidc-rbac/o11y.yaml).

## Contents

- [Pick an auth mode](#pick-an-auth-mode)
- [OIDC setup](#oidc-setup)
- [Policies](#policies)
- [Constraints](#constraints)
- [Examples: from token claims to policy](#examples-from-token-claims-to-policy)
- [What a refused caller sees](#what-a-refused-caller-sees)
- [Things to know](#things-to-know)
- [Use your own authenticator](#use-your-own-authenticator)

## Pick an auth mode

Set `server.auth` to one of three modes.

| Mode | Who gets in | Limits per caller | Use it for |
|---|---|---|---|
| `none` | Everyone | No | Your own machine |
| `token` | Anyone with the shared token | No | A small trusted team |
| `oidc` | Anyone with a valid JWT from your issuer | Yes, via policies | Shared or production use |

Rules that always apply:

- `none` only works on a loopback address. Config refuses it on `0.0.0.0`.
- `token` reads the token from the `O11Y_PROXY_TOKEN` environment variable.
- If `O11Y_PROXY_TOKEN` is unset, `token` mode refuses every request.
- `/healthz` and `/openapi.json` never need a token.
- Every other route needs `Authorization: Bearer <token>`.
- The CLI is never limited. It runs as the local user.

To listen on all interfaces, set `bind`:

```yaml
server:
  bind: 0.0.0.0   # default is 127.0.0.1
  auth: oidc
```

## OIDC setup

### What your issuer must provide

- Signing keys, published as a JWKS.
- Either a discovery document at `{issuer}/.well-known/openid-configuration`, or a direct `jwks_uri`.
- Asymmetric signatures, such as RS256, ES256 or EdDSA.
- An `aud` claim that names this service.
- An `exp` claim.
- A claim that names the caller's role. You pick which claim.
  The issuer must set it, not the caller. See [Claims the issuer must control](#claims-the-issuer-must-control).

### Claims the issuer must control

The proxy trusts every claim your issuer signs.

- A caller cannot edit a claim. The signature would no longer verify.
- But a signature only proves who issued the token.
- It does not prove who chose the claims.

So every claim you configure must be set by the issuer, never by the caller:

- `role_claim`
- every `allowed_claim`
- `identity_claim`

Watch for these:

- **Requester-chosen claims.** Some issuers copy values from the token request into the token.
  AWS outbound identity federation, for example, turns request tags into `key=value` claims.
  Never point `role_claim` or `allowed_claim` at claims like these.
  Put a token broker in front that sets claims from the caller's verified identity.
  See [Example 6](#example-6-workload-identity-through-a-token-broker).
- **User-editable profile fields.** Some issuers copy profile attributes into the token.
  If users can edit those attributes, they can pick their own role.
  Use admin-managed groups or roles instead.
- **`default_policy` covers everyone the issuer will sign for.**
  That is any account that can get a token with your `aud`.
  If the issuer has open sign-up, that is anyone.
  Keep `default_policy` small, or leave it unset.

### Config

```yaml
server:
  bind: 0.0.0.0
  auth: oidc
  oidc:
    issuer: https://issuer.example.com   # must equal the token's iss, exactly
    audience: o11y-proxy                 # token's aud must contain this
    role_claim: o11y.role                # where to find the role
    identity_claim: sub                  # who the caller is (default: sub)
    default_policy: readonly             # optional: for tokens with no matching role
```

| Key | Required | Default | What it does |
|---|---|---|---|
| `issuer` | Yes | | The exact `iss` to accept. Discovery is fetched from under it. |
| `audience` | Yes | | A string or a list. The token's `aud` must contain one. |
| `role_claim` | One of these two | | Claim path holding the role. A string or a list of strings. With `spiffe`, it holds one SPIFFE ID instead. |
| `default_policy` | One of these two | | Policy for a token whose roles match no policy. |
| `identity_claim` | No | `sub` | Claim path naming the caller. |
| `spiffe` | No | | Read roles out of a SPIFFE ID in `role_claim`. See [SPIFFE IDs as roles](#spiffe-ids-as-roles). |
| `jwks_uri` | No | from discovery | Fetch keys here and skip discovery. |
| `algorithms` | No | see below | Accepted signing algorithms. Asymmetric only. |
| `jwks_refresh_seconds` | No | `300` | How often keys are refetched. |
| `leeway_seconds` | No | `60` | Clock skew allowed on `exp` and `nbf`. |

How `algorithms` is chosen:

- If you set it, only those are accepted.
- If not, the issuer's advertised algorithms are used.
- Symmetric algorithms like HS256 are always refused.
- If the issuer advertises nothing usable, RS256 is used.

### Claim paths

A claim path is a dotted path into the token's claims.

- `o11y.role` reads `{"o11y": {"role": "support"}}`.
- Dots inside a claim name also work.
- `https://example.com/roles` reads `{"https://example.com/roles": [...]}`.
- The longest matching key wins at each level.

### SPIFFE IDs as roles

Some issuers name a workload in `sub` and send no role claim.
If `sub` is a [SPIFFE ID](https://spiffe.io/), the role can be read out of its path.

The SPIFFE spec fixes the ID's syntax, not what its path means.
Each issuer picks its own layout. So you describe it: one entry per layout, each with

- `pattern`: what the ID's path looks like, and which segments to keep.
- `policy_names`: how to build policy names from those segments, in order.

```yaml
server:
  oidc:
    role_claim: sub                       # the claim holding the SPIFFE ID
    spiffe:
      trust_domain: broker.example.com
      paths:
        - pattern: /aws/{account}/{region}/role/{role}
          policy_names: ["{account}/{role}", "{role}"]
        - pattern: /aws/{account}/role/{role}     # the same IDs, without a region
          policy_names: ["{account}/{role}", "{role}"]
```

With `spiffe:` set, `role_claim` holds one SPIFFE ID, as a string.
It is not a role or a list of roles.

**`pattern`** is matched one segment at a time:

| Segment | Matches |
|---|---|
| `aws`, `role`, ... | That exact segment. Case matters. |
| `*` | Any one segment. Not kept. |
| `{name}` | Any one segment, kept as `name`. |

- A name starts with a lowercase letter or `_`. Then lowercase letters, digits or `_`.
- A pattern must match every segment. The segment count must be equal.
- A name can appear once per pattern.
- The names mean nothing to the proxy. `{account}` is just a name you chose.

**`policy_names`** are filled in from that pattern's kept segments:

- `"{account}/{role}"` becomes `111122223333/sre`.
- Text outside `{}` is kept as is.
- An entry may only use names its own pattern keeps.

How a token is matched:

1. The ID must be a valid SPIFFE ID in `trust_domain`.
   No port, query, fragment, `%` escapes, empty, `.` or `..` segments.
   The scheme and trust domain must be lowercase.
2. A pattern must match it.
3. That pattern's `policy_names` are filled in, in order.
4. The first name with a policy wins. So `111122223333/sre` beats `sre`.
5. No match uses `default_policy`. Otherwise the caller gets `403`.
   The message shows the ID and the names it gave.
6. If two patterns match one ID and give different names, the caller gets `403`.
   Fix the patterns. No guess is made.
7. A role claim that is not a string gets `403`, even with a `default_policy`.

**Policy names must not collide.**
A kept segment is chosen by whoever named the workload.
So config refuses any two `policy_names` entries that could give two different IDs the same name.

- **Separate every `{name}` with a character no segment can hold.**
  Segments hold letters, digits, `.`, `-` and `_`. So use `/`, `:`, `@` or a space.
  `{account}/{role}` is fine.
  `{account}-{role}` is refused: a role named `111122223333-admin`, in any account, would fill `{role}` to the same name.
- **Keep different layouts apart with fixed text.**
  `{role}` for AWS and `{sa}` for Kubernetes are refused together: a service account named `sre` would get the AWS `sre` policy.
  Write `k8s:{sa}` instead.
- **The same entry under several patterns is allowed.**
  That is how one issuer's layouts, like with and without a region, say they mean the same thing.

Config checks these at boot:

- Patterns and names are well formed.
- Every `policy_names` entry uses only names its pattern keeps.
- No two different entries can produce the same name.
- Every policy, except `default_policy`, can be produced by some entry.
  `111122223333:sre` is refused, since no entry above can give it.
  But `111122223333_sre` is accepted: `{role}` gives it, for a role with that name.

Other layouts are just other config. Istio-style IDs, for example:

```yaml
spiffe:
  trust_domain: cluster.local
  paths:
    - pattern: /ns/{namespace}/sa/{sa}
      policy_names: ["k8s:{namespace}/{sa}", "k8s:{sa}"]
```

**Pin accounts for broad access.**

- A role name is only unique inside one account.
- A role-only policy, like `sre`, matches that role in every account.
- Anyone who can create a role called `sre` in any account your broker signs for gets it.
- So keep role-only policies small.
- Put broad access, like `raw: allow` or `sources: "*"`, on account-pinned policies.
- Or pin the account in the pattern itself: `/aws/111122223333/*/role/{role}`.

Don't know the account IDs yet? Start with role-only policies.
A refused token's `403` message shows the account, so you can pin it later.
This only works without `default_policy`, since a default means no refusal.

Not sure every ID has the same layout? List one pattern per layout.
An ID that matches no pattern gets no role. It is never matched loosely.

### Key rotation

- Keys refresh every `jwks_refresh_seconds`.
- A token with an unknown `kid` triggers one early refetch.
- Early refetches happen at most once every 10 seconds.
- If the issuer is down, the keys already held keep working.
- If no keys have loaded yet, requests get `503` with `Retry-After`.

## Policies

A policy is a named set of rules.

- The token's role picks the policy.
- The role must match exactly one policy name.
- No match uses `default_policy`, if set. Otherwise the caller gets `403`.
- Two matching roles is a `403`. Policies are never merged.
- With `spiffe:`, the first `policy_names` entry with a policy wins. That is precedence, not a merge.

```yaml
policies:
  support:
    sources: [prod_metrics, prod_logs]   # or "*" for all
    raw: deny                            # default: deny
    modes: [summary, sample]             # default: all modes
    max_limit: 500                       # default: no cap
    max_lookback: 7d                     # default: no cap
    constraints: []                      # see next section
```

| Key | Default | What it does |
|---|---|---|
| `sources` | required | Sources this role may see and query. A list, or `"*"`. |
| `raw` | `deny` | Whether `raw` queries are allowed. |
| `modes` | all | Allowed `mode` values. |
| `max_limit` | none | Highest `limit` a query may ask for. |
| `max_lookback` | none | How far back `from` may reach. Units: `s m h d w`. |
| `constraints` | `[]` | Filter rules. See below. |

What these do to a request:

- A source outside `sources` is hidden from `/v1/sources`.
- Querying it returns `403`.
- A `limit` over `max_limit` returns `403`. It is never silently lowered.
- A `from` older than `max_lookback` returns `403`.
- If a query leaves out `limit`, the default is lowered to fit `max_limit`.

Config checks these at boot:

- Every source a policy names must exist.
- `raw: allow` cannot be combined with constraints. Raw queries skip filters.
- Policies require `auth: oidc`. Otherwise they would never be enforced.

## Constraints

A constraint is a rule about one filter field.

```yaml
constraints:
  - sources: [prod_metrics]      # which sources. Default: all of the policy's sources
    field: labels.project        # the canonical filter field
    require: true                # the query must filter on this field
    allowed_claim: o11y.projects # the values allowed come from the token
```

| Key | What it does |
|---|---|
| `field` | The filter field this rule is about. Required. |
| `sources` | Which sources it applies to. A list, or `"*"`. Default `"*"`. |
| `require` | The query must have an `eq` or `in` filter on `field`. |
| `inject` | If the query has no filter on `field`, add one. |
| `allowed` | Values the filter may use. A list, or `"*"` for any value. |
| `allowed_claim` | Read the allowed values from this claim instead. |

Set exactly one of `allowed` or `allowed_claim`.

How a constraint checks a query:

1. **Field missing, `inject: true`.** The filter is added. One value becomes `eq`. Several become `in`.
2. **Field missing, `require: true`.** The query is refused with `403`.
3. **Field missing, neither.** The query runs as is.
4. **Field present.** Its operator must be `eq` or `in`.
5. **Field present.** Every value must be in the allowed list.

Why only `eq` and `in`:

- `neq`, `regex`, `contains` and `exists` can match values outside the list.
- So they are refused on a constrained field.

How `allowed_claim` reads the token:

- A list of strings or numbers is used as is.
- A single string or number becomes a one-item list.
- A missing claim means no values are allowed.
- A claim that is a map or nested list is refused with `403`.
- Values are compared as strings. `42` matches `"42"`.
- Injected values are sent as strings too.
- A filter value on a constrained field must be a string, number or boolean. Maps and nested lists get `403`.

`require` or `inject`?

- Use `require` when the caller should choose. Example: support staff name the project they are looking at.
- Use `inject` when the caller should never think about it. Example: tenant isolation.

## Examples: from token claims to policy

Each example shows three things.

1. The token's claims.
2. The config.
3. What happens to real requests.

All examples assume this `server` block:

```yaml
server:
  bind: 0.0.0.0
  auth: oidc
  oidc:
    issuer: https://issuer.example.com
    audience: o11y-proxy
    role_claim: o11y.role
```

### Example 1: support must name a project

Support staff may read metrics.
They must say which project they are looking at.
They may only pick projects listed in their token.

**Token claims**

```json
{
  "iss": "https://issuer.example.com",
  "aud": "o11y-proxy",
  "sub": "dana@example.com",
  "exp": 1790000000,
  "o11y": {
    "role": "support",
    "projects": ["acme-web", "acme-api"]
  }
}
```

**Config**

```yaml
policies:
  support:
    sources: [prod_metrics]
    max_lookback: 7d
    constraints:
      - field: labels.project
        require: true
        allowed_claim: o11y.projects
```

**What happens**

- No project filter: `403`.
  The message says: `requires a filter on labels.project with op eq or in; allowed values: "acme-web", "acme-api"`.
- `labels.project eq acme-web`: runs.
- `labels.project in [acme-web, acme-api]`: runs.
- `labels.project eq other-co`: `403`. The message names `other-co`.
- `labels.project regex acme.*`: `403`. Only `eq` and `in` are allowed.
- `from: now-30d`: `403`. The cap is 7 days.
- `prod_logs` is not listed in `/v1/sources` for this caller.

### Example 2: tenant isolation without the caller knowing

A customer's agent queries logs.
It should only ever see its own tenant.
It should not need to add a filter.

**Token claims**

```json
{
  "iss": "https://issuer.example.com",
  "aud": "o11y-proxy",
  "sub": "agent-7",
  "exp": 1790000000,
  "o11y": { "role": "tenant", "tenant_id": 4012 }
}
```

**Config**

```yaml
policies:
  tenant:
    sources: [app_logs]
    modes: [summary, sample]
    max_limit: 200
    constraints:
      - field: attributes.tenant_id
        inject: true
        allowed_claim: o11y.tenant_id
```

**What happens**

- Any query on `app_logs` gets `attributes.tenant_id = 4012` added.
- You can see it in `meta.native_queries`. Nothing is hidden.
- `attributes.tenant_id eq 4012` written by the caller: runs unchanged.
- `attributes.tenant_id eq 9999`: `403`.
- `mode: full`: `403`.
- No `limit` given: the default drops to fit 200.
- `limit: 1000`: `403`.

### Example 3: roles as a list, with an admin role

Your issuer puts several roles in one list.
Only one of them names a policy here.

**Token claims**

```json
{
  "iss": "https://issuer.example.com",
  "aud": "o11y-proxy",
  "sub": "sam",
  "exp": 1790000000,
  "o11y": { "role": ["employee", "on-call", "sre"] }
}
```

**Config**

```yaml
policies:
  sre:
    sources: "*"
    raw: allow
  support:
    sources: [prod_metrics]
```

**What happens**

- `employee` and `on-call` have no policy. They are ignored.
- `sre` matches. The caller can query every source, including raw queries.
- A token with both `sre` and `support` is refused with `403`.
  Policies are never combined. Issue the token with one of them.

### Example 4: a namespaced claim, and a default for everyone else

Your issuer uses a claim name with dots and slashes.
Anyone without a known role gets read-only access to one source.

**Token claims**

```json
{
  "iss": "https://issuer.example.com",
  "aud": ["o11y-proxy", "billing"],
  "sub": "lee",
  "exp": 1790000000,
  "https://example.com/roles": ["viewer"]
}
```

**Config**

```yaml
server:
  bind: 0.0.0.0
  auth: oidc
  oidc:
    issuer: https://issuer.example.com
    audience: o11y-proxy
    role_claim: https://example.com/roles
    default_policy: readonly

policies:
  readonly:
    sources: [prod_errors]
    modes: [summary]
  sre:
    sources: "*"
```

**What happens**

- The role claim path is the whole claim name. It still resolves.
- `aud` is a list. It contains `o11y-proxy`, so the token is accepted.
- `viewer` has no policy, so `readonly` is used.
- The caller sees only `prod_errors`, in `summary` mode.

### Example 5: a fixed rule, no claim needed

Everyone with the `oncall` role may query logs.
But only production logs, and never raw SQL.

**Token claims**

```json
{
  "iss": "https://issuer.example.com",
  "aud": "o11y-proxy",
  "sub": "kim",
  "exp": 1790000000,
  "o11y": { "role": "oncall" }
}
```

**Config**

```yaml
policies:
  oncall:
    sources: [app_logs, prod_metrics]
    constraints:
      - sources: [app_logs]
        field: attributes.environment
        inject: true
        allowed: [production]
```

**What happens**

- Every `app_logs` query gets `attributes.environment = production` added.
- `prod_metrics` is not affected. The constraint names only `app_logs`.
- `attributes.environment eq staging` on `app_logs`: `403`.
- A `raw` query: `403`. `raw` defaults to `deny`.

### Example 6: workload identity through a token broker

The callers are agents running under cloud IAM roles, not people.
The cloud's own issuer lets the requester add claims, so it cannot be trusted for roles.
A token broker verifies the cloud token and issues its own:

- `sub` is a SPIFFE ID built from the caller's IAM role.
- The role and projects come from the broker's own mapping for that IAM role.
- The caller cannot choose any of them.

**Token claims**

```json
{
  "iss": "https://broker.example.com",
  "aud": "o11y-proxy",
  "sub": "spiffe://broker.example.com/aws/111122223333/ap-southeast-1/role/metrics-reader",
  "exp": 1790000000,
  "o11y": {
    "role": "metrics-reader",
    "projects": ["acme-web", "acme-api"]
  }
}
```

**Config**

```yaml
server:
  bind: 0.0.0.0
  auth: oidc
  oidc:
    issuer: https://broker.example.com   # the broker, never the cloud issuer
    audience: o11y-proxy
    role_claim: o11y.role
    identity_claim: sub                  # the default

policies:
  metrics-reader:
    sources: [prod_metrics]
    constraints:
      - field: labels.project
        inject: true
        allowed_claim: o11y.projects
```

**What happens**

- The caller's identity is the SPIFFE ID. It names an IAM role, not a person.
  Access can be traced to a role, not to a human.
- `metrics-reader` matches. The caller sees only `prod_metrics`.
- A query with no project filter gets `labels.project in [acme-web, acme-api]` added.
- `labels.project eq other-co`: `403`.
- Moving the IAM role to another account or region changes the `sub`.
  Only the broker's mapping needs to follow. The proxy config stays the same.

**If the broker sets only `sub`**

Read the role out of the SPIFFE ID instead. See [SPIFFE IDs as roles](#spiffe-ids-as-roles).

```yaml
server:
  bind: 0.0.0.0
  auth: oidc
  oidc:
    issuer: https://broker.example.com
    audience: o11y-proxy
    role_claim: sub
    spiffe:
      trust_domain: broker.example.com
      paths:
        - pattern: /aws/{account}/*/role/{role}
          policy_names: ["{account}/{role}", "{role}"]

policies:
  "111122223333/sre":        # sre in the prod account
    sources: "*"
    raw: allow
  sre:                       # sre in any other account
    sources: [prod_metrics]
  metrics-reader:            # metrics-reader in any account
    sources: [prod_metrics]
```

| Token `sub` ends in | Policy |
|---|---|
| `/aws/111122223333/ap-southeast-1/role/sre` | `111122223333/sre` |
| `/aws/444455556666/eu-west-1/role/sre` | `sre` |
| `/aws/<any account>/<any region>/role/metrics-reader` | `metrics-reader` |
| `/aws/<any account>/<any region>/role/intern` | `403`. The message names `<account>/intern, intern`. |

- The region is skipped with `*`. One policy covers every region.
- `{account}/{role}` is listed first, so the account-pinned policy wins.
- Broad access sits on the account-pinned policy. The role-only `sre` is kept small.
- Projects cannot come from the ID. Without a broker claim, use a fixed `allowed` list.

## What a refused caller sees

| Status | `error` | When |
|---|---|---|
| `401` | `unauthorized` | No token, bad signature, wrong issuer or audience, expired. |
| `403` | `forbidden` | Valid token, but the policy does not allow this request. |
| `503` | `auth_unavailable` | Signing keys are not loaded yet. Retry later. |

Every body looks like this:

```json
{ "error": "forbidden", "message": "source \"prod_logs\" requires a filter on labels.project with op eq or in; allowed values: \"acme-web\"" }
```

The message is written for an agent to act on.
It names the field, the operator, the values or the cap to change.

### `/v1/context` under a policy

`/v1/context` builds its own queries. So it works a little differently.

- It never queries a source outside the policy.
- A source that needs a filter it cannot add shows up in `errors[]`, with code `forbidden`.
- Other sources still answer. The status is still `200`.
- Its own default lookback shrinks to fit `max_lookback`.
- Its own default limit shrinks to fit `max_limit`.
- Its own mode falls back to one the policy allows. `summary` is the last choice.
- A window you give it yourself is checked as given.
- An `error_id` lookup is refused on a constrained source. An ID cannot be scoped by a filter.

Tip: prefer `inject` over `require` for sources an agent will reach through `/v1/context`.

## Things to know

- **`/healthz` is open.** It lists every source name and its status. No data.
- **With auth on, `/healthz` is cached.** It checks the backends at most once every 5 seconds.
- **With auth on, `/healthz` shows only `status`.** Error messages are dropped, since they can name hosts.
- **Bodies are read after auth.** A request with no valid token is refused before its JSON is parsed.
- **`/metrics` is not open.** It needs a token like the data routes.
- **The CLI is not limited.** It runs as the local user, or through the daemon's Erlang cookie.
- **One role per token.** Two matching roles is a `403`.
- **Policies are checked before any backend is called.** A refusal never reaches a backend.
- **Injected filters are visible.** Check `meta.native_queries`.
- **Constraints work on canonical fields.** Use the field names from `/v1/sources/{name}/schema`.
- **Field names differ per backend.** That is why a constraint names its sources.

## Use your own authenticator

Authentication is an Elixir behaviour, `O11yProxy.Auth`, with one callback.

```elixir
@callback authenticate(headers :: [{String.t(), String.t()}]) ::
            {:ok, O11yProxy.Caller.t()}
            | {:error, {:unauthorized | :forbidden | :unavailable, String.t()}}
```

If you embed o11y-proxy in your own application, you can replace the module behind a mode:

```elixir
config :o11y_proxy, :authenticators, %{oidc: MyApp.O11yAuth}
```

- Return a `%O11yProxy.Caller{}` with a `policy` to limit the caller.
- Return a caller with `policy: nil` for full access.
- Policy enforcement stays the same. It lives in one place, not in the authenticator.

To pass extra `Req` options to key fetching, such as a custom CA, set:

```elixir
config :o11y_proxy, :oidc_req_options, connect_options: [transport_opts: [cacertfile: "/path/ca.pem"]]
```

The single-file binary cannot load your code. There, use the built-in modes.
