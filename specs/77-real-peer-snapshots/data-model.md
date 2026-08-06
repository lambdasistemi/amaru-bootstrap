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
  (committer time, UTC) and `cardano-configurations.locked.rev`: the
  equivalence check's only local inputs.
- State invariant: pinned configs rev == rev resolved by R-RULE from
  `amaru.locked.lastModified` (I3, checked online).
