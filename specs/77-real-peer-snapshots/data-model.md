# Data model — #77

- D1 peer-snapshot.json (per network) — upstream schema
  `peer-snapshot.schema.json` (draft 2020-12) from the pinned amaru source.
  Validation invariants: required keys `NetworkMagic`,
  `NodeToClientVersion`, `Point`, `bigLedgerPools`; per-network
  `NetworkMagic` ∈ {mainnet: 764824073, preprod: 1, preview: 2};
  `bigLedgerPools` non-empty for the default package (I4).
- D2 CONFIGS_COMMIT_CACHE — line-oriented `key: value`; required line
  `sha: <40-hex configs rev>`; optional `etag`/`last-modified` omitted
  (offline build). Value must equal the flake-pinned configs rev.
- D3 flake.lock nodes — `amaru.locked.rev` + `amaru.locked.lastModified`
  (committer time, UTC) and `cardano-configurations.locked.rev`: local
  inputs to the anchor checks and the bump-time tool.
- D4 (v3) resolution record `nix/peer-snapshots/resolution.json` — required
  fields: `amaru_rev` (40-hex), `amaru_committer_date_utc` (ISO-8601 Z),
  `configs_rev` (40-hex), `resolved_at_utc` (ISO-8601 Z), `query_url`
  (string), `snapshots.<network>.sha256` (64-hex) for exactly mainnet,
  preprod, preview. Updated only at pin bumps by the bump-time tool.
- State invariants (I3, all offline): D4.amaru_rev == D3.amaru.rev;
  D4.configs_rev == D3.cardano-configurations.rev; D4 per-network sha256 ==
  sha256 of the flake-input files == sha256 of the staged files.
- State invariant (I3b, bump-time only): D4.configs_rev == rev resolved by
  R-RULE from D4.amaru_committer_date_utc at resolution time; recorded, not
  re-checked in CI (future-dated / backdated edges — see research R-EDGE).
