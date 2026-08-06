# Tasks — #77

## S1 — feat(nix): embed real pinned peer snapshots

- [x] T1 Add `cardano-configurations` non-flake input pinned at
  `4a9b69103507b124679fcb185eeabd4dc15e9c75`; thread input + rev into
  `nix/amaru.nix`.
- [x] T2 Stage real per-network files + `CONFIGS_COMMIT_CACHE`
  (`sha: <pinned rev>`) in `preBuild`; keep
  `AMARU_SKIP_PEER_SNAPSHOT_FETCH=1`.
- [x] T3 In-sandbox validation before cargo: presence, schema
  (check-jsonschema vs pinned amaru schema), per-network NetworkMagic,
  non-empty bigLedgerPools; loud per-network failure (I1/I2/I4). Ships a
  permanent `peer-snapshot-negative-control` flake check (build with a
  broken staged file must fail) wired into `just build-gate`.
- [x] T4 Split placeholder path into explicit `amaru-placeholder-dev`
  attr; default `amaru` never uses placeholders (R4).

## S2 (v3) — feat(ci): anchor peer-snapshot resolution evidence

- [x] T5 `nix/peer-snapshots/resolution.json` (D4) + anchor assertions in
  the in-sandbox validation (revs + per-network sha256 vs record) + a
  tampered-file fault in `peer-snapshot-negative-control` (I3 negative
  control).
- [x] T6 `checks.<sys>.peer-snapshot-anchor` (F5, offline) in
  `just build-gate` and the ci.yml Build Gate list; no live-API CI step.
- [x] T7 `docs/peer-snapshots.md` + mkdocs nav: derived rule, current
  resolution, anchored-enforcement rationale (future-dated pin /
  backdated commit edges), #205 bump procedure (R5).
- [x] T8 `scripts/resolve-peer-snapshots` (F1, bump-time, check/write
  modes) + just recipe `resolve-peer-snapshots` (F4) (I3b).
- [x] T9 R7 parity/lint: `peer-snapshot-negative-control` added to the
  ci.yml Build Gate list; shellcheck check enumerates
  `scripts/resolve-peer-snapshots`.
