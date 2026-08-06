# Tasks — #77

## S1 — feat(nix): embed real pinned peer snapshots

- [ ] T1 Add `cardano-configurations` non-flake input pinned at
  `4a9b69103507b124679fcb185eeabd4dc15e9c75`; thread input + rev into
  `nix/amaru.nix`.
- [ ] T2 Stage real per-network files + `CONFIGS_COMMIT_CACHE`
  (`sha: <pinned rev>`) in `preBuild`; keep
  `AMARU_SKIP_PEER_SNAPSHOT_FETCH=1`.
- [ ] T3 In-sandbox validation before cargo: presence, schema
  (check-jsonschema vs pinned amaru schema), per-network NetworkMagic,
  non-empty bigLedgerPools; loud per-network failure (I1/I2/I4).
- [ ] T4 Split placeholder path into explicit `amaru-placeholder-dev`
  attr; default `amaru` never uses placeholders (R4).

## S2 — feat(ci): peer-snapshot equivalence check + docs

- [ ] T5 `scripts/verify-peer-snapshot-resolution` (I3) + just recipe
  `verify-peer-snapshots`.
- [ ] T6 CI: networked equivalence step wired into the workflow.
- [ ] T7 `docs/peer-snapshots.md` + mkdocs nav: derived rule, current
  resolution, amaru-bump re-resolution procedure (epic #205 hook).
