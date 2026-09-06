[
  calls: [
    forbidden: [
      # `String.to_atom/1` on anything a caller controls grows the atom table without
      # bound, and this process parses attacker-adjacent input all day: query bodies,
      # backend responses, YAML config. `String.to_existing_atom/1` or an explicit
      # allow-list instead — see how O11yProxy.Query.parse/2 matches signals and modes
      # against a fixed list rather than converting.
      {"O11yProxy.*", ["String.to_atom"]}
    ]
  ]
]
