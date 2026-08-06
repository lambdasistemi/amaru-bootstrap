# Plan — real pinned peer-snapshot contents

Issue: #77 · Spec: [spec.md](spec.md) · Rule: [research.md](research.md)

## Strategy

Consume `cardano-foundation/cardano-configurations` as a new non-flake,
SHA-pinned input at the rev the upstream rule selects for the current amaru
pin (R-RESOLVED: `4a9b69103507b124679fcb185eeabd4dc15e9c75`). Stage its real
per-network files (plus a provenance `CONFIGS_COMMIT_CACHE`) in
`nix/amaru.nix` `preBuild`, validate them in-sandbox before cargo runs, and
add an online equivalence check that re-derives the rule end-to-end.

## Constraints

- Constitution I: additive staging only; no upstream file patched/vendored.
- Constitution III: rev pinned in `flake.nix`/`flake.lock`, never a branch.
- Constitution IV: nix-first; validation runs inside the build sandbox;
  the equivalence check needs network and therefore lives OUTSIDE nix
  sandbox builds (script + just recipe + CI step on the nixos runner).
- The default `amaru` package must never silently use placeholders (R4/I4).

## Live boundaries

- GitHub commits API + raw.githubusercontent (equivalence check only;
  build itself stays offline).

## Design

1. `flake.nix`: input `cardano-configurations` (`flake = false`, URL form
   `github:cardano-foundation/cardano-configurations/<rev>`); passed to
   `nix/amaru.nix`.
2. `nix/amaru.nix`:
   - default mode stages `${cardano-configurations}/network/<net>/cardano-node/peer-snapshot.json`
     for mainnet/preprod/preview and writes
     `config/peer-snapshots/CONFIGS_COMMIT_CACHE` with
     `sha: <pinned configs rev>` (rev string threaded from the flake input
     so it cannot drift from the pinned source);
   - `preBuild` validation (before cargo): every staged file exists,
     validates against `${amaru}/crates/amaru-node/config/peer-snapshots/peer-snapshot.schema.json`
     via `check-jsonschema`, has the per-network `NetworkMagic`
     (764824073/1/2), and non-empty `bigLedgerPools`; any failure aborts
     the derivation naming network + reason (I1/I2);
   - placeholder generator kept ONLY behind an explicit
     `peerSnapshots = "placeholder-dev"` argument surfaced as separate
     attr `amaru-placeholder-dev` (never referenced by checks/images/CI
     defaults) (R4);
   - keep `AMARU_SKIP_PEER_SNAPSHOT_FETCH = "1"` (build must not attempt
     network).
3. (v3) `nix/peer-snapshots/resolution.json` — the R6 anchored record:
   `{amaru_rev, amaru_committer_date_utc, configs_rev, resolved_at_utc,
   query_url, snapshots.{mainnet,preprod,preview}.sha256}`. Committed;
   changes only at deliberate pin bumps.
4. (v3) Anchored enforcement, fully offline (I3):
   - flake.nix threads `inputs.amaru.rev` and the configs rev into
     `nix/amaru.nix`; the in-sandbox validation additionally asserts each
     staged file's sha256 equals the record's value and both revs match
     the record (loud per-network RED; a tampered-file fault joins the
     `peer-snapshot-negative-control` fault set);
   - a fast dedicated offline flake check `peer-snapshot-anchor`
     re-asserts record⇔flake.lock rev agreement and record⇔input byte
     hashes for clear failure attribution without building amaru; added
     to `just build-gate` AND the ci.yml Build Gate list. There is NO
     live-API CI step.
5. (v3) `scripts/resolve-peer-snapshots` (bash, shellcheck-clean): the
   BUMP-TIME tool (I3b), never run in CI. Re-derives the rule online
   (commits API `until=`, raw fetch), byte-compares against the flake
   input, and writes/refreshes `resolution.json` (check-only mode prints
   the proposed record and diffs; write mode updates it), logging the
   resolved rev and query evidence. Optional `GITHUB_TOKEN`, `FLAKE_LOCK`
   override. `justfile` recipe `resolve-peer-snapshots` wraps it with
   nix-provisioned curl/jq/coreutils/diffutils.
5b. (v3, R7) CI parity + lint: `peer-snapshot-negative-control` and
   `peer-snapshot-anchor` join the ci.yml Build Gate list; the repo
   shellcheck check (`nix/checks.nix`) enumerates
   `scripts/resolve-peer-snapshots`.
5c. (v3) `docs/peer-snapshots.md` (+ mkdocs nav): rule (R-RULE), current
   resolution (R-RESOLVED), anchored-enforcement rationale with the
   future-dated-pin and backdated-commit edges (both bite only at the
   resolution event; the bump record logs the resolved rev + query
   evidence), and the #205 procedure: bump amaru pin → run
   `just resolve-peer-snapshots` (write mode) → update configs input rev →
   review the `resolution.json` diff → CI anchored checks enforce.
6. Negative controls: I1/I2 ship as a permanent flake check
   `peer-snapshot-negative-control` (e.g. `testers.testBuildFailure` over
   an amaru variant with a deliberately broken staged file) added to
   `just build-gate`, so the in-sandbox validation is forever proven able
   to fail. One-off falsification evidence (wrong-rev equivalence run,
   per-variant break runs) is additionally recorded in the ticket runtime
   root.

## Slices (bisect-safe, trunk-landing)

- S1 `feat(nix): embed real pinned peer snapshots` — flake input, staging,
  provenance cache, in-sandbox validation, placeholder-dev split.
  Invariants I1, I2, I4. Tasks T1–T4.
- S2 (v3) `feat(ci): anchor peer-snapshot resolution evidence` — anchored
  record + offline anchor checks + bump-time tool + CI parity/lint + docs.
  Invariants I3, I3b. Tasks T5–T9. (The v2 live-in-CI slice was retired by
  the 2026-08-06 operator ruling before acceptance; its candidate is
  preserved at `refs/backup/77-s2-candidate` as an optional seed.)

## Status

- Planning committed; gate frozen and falsified; S1+S2 dispatched to a
  Codex commit owner (OWNER topology).
