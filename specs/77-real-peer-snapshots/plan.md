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
3. `scripts/verify-peer-snapshot-resolution` (bash, shellcheck-clean):
   reads `flake.lock` (amaru rev + lastModified, configs rev), re-derives
   the rule online (commits API `until=`, raw file fetch), byte-compares
   fetched files against the flake-input store path, exits non-zero
   printing pinned-vs-resolved on any mismatch (I3). Accepts optional
   `GITHUB_TOKEN`. Nix-provided runtime deps (curl, jq) via `nix shell`
   in the just recipe.
4. `justfile`: recipe `verify-peer-snapshots` wrapping the script;
   CI workflow gets a networked step invoking it (after Build Gate).
5. `docs/peer-snapshots.md` (+ mkdocs nav): the derived rule (R-RULE),
   current resolution (R-RESOLVED), and the amaru-bump re-resolution
   procedure for epic #205: on each amaru pin bump — take new
   `lastModified` → query commits API `until=` → update the
   `cardano-configurations` input rev → run `just verify-peer-snapshots`
   → build.
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
- S2 `feat(ci): peer-snapshot equivalence check + docs` — script, just
  recipe, CI step, docs page. Invariants I3. Tasks T5–T7.

## Status

- Planning committed; gate frozen and falsified; S1+S2 dispatched to a
  Codex commit owner (OWNER topology).
