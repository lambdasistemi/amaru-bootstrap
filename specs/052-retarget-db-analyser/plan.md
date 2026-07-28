# Implementation Plan: Retarget Producer at db-analyser

**Branch**: `052-retarget-db-analyser` | **Date**: 2026-07-28 |
**Spec**: [spec.md](./spec.md)

## Summary

Replace the producer's custom chain-database queries with two pinned
`db-analyser` modes: a no-analysis, minimum-validation tip poll and one forward
block trace that writes the three target records Amaru needs. Prove all six
points against the real synthesized database, then remove the redundant
Haskell executable and align current documentation. The work lands in three
bisect-safe commits: behavior and proof, build/image deletion, and
documentation.

## Technical Context

**Language/Version**: Bash with `set -euo pipefail`; Nix; Cabal 3.0 metadata
for GHC 9.6; Markdown

**Primary Dependencies**: pinned `ouroboros-consensus` `db-analyser`,
haskell.nix, `gawk`, `gnused`, `jq`, Amaru, Docker tools

**Storage**: cardano-node immutable ChainDB input; compact JSON run evidence;
RocksDB-backed Amaru bundle output

**Testing**: bats, real synthesized-chain Nix assertions, exact live-surface
audit, flake/image inspection, deterministic bundle manifests, semantic Amaru
startup checks, and the Docker live cardano-node verifier

**Target Platform**: `x86_64-linux`

**Project Type**: Nix-first Bash/Haskell producer and container image

**Performance Goals**: readiness uses no whole-chain analysis; the one-shot
forward scan remains comparable to one following ledger replay and does not
become a poll-loop cost

**Constraints**: no bounded anchoring, no defensive multi-version parser, no
dependency repin, no historical rewrite, no `site/**` regeneration, exact six
points, origin fails closed, deterministic bundle equivalence

**Scale/Scope**: one producer script, one package/application/check/image
surface, three test-double owners, one real point check, six current
documentation surfaces, three reviewed commits

## Constitution Check

| Principle | Status | Evidence |
|---|---|---|
| I. No forks | PASS | Uses the existing SHA-pinned stock IOG executable without source changes |
| II. Stock tools, custom orchestration | PASS | Removes the replaceable in-repo query executable and retains only small shell orchestration |
| III. Reproducibility by SHA pinning | PASS | `flake.lock`, `cabal.project` pins, and the Amaru pin remain unchanged |
| IV. Nix-first, haskell.nix | PASS | The real synthesized database, package graph, image, and CI outputs are asserted through flake checks |
| V. Smallest provable step | PASS | One behavior slice proves the six-point contract before two deletion/alignment slices remove surface |

Post-design check: PASS. The plan introduces no fork, upstream patch,
long-lived abstraction, schema, or unpinned dependency.

## Boundary Review

The changed gathering boundary is the producer opening a real cardano-node
ChainDB and handing selected points to Amaru. Unit traces cannot prove the
filesystem permissions, pinned tool invocation, database format, or resulting
bundle consumption. `gate.sh` therefore retains
`just live-bootstrap-producer`; the PR cannot leave draft without a fresh
passing run.

## Project Structure

### Documentation for this ticket

```text
specs/052-retarget-db-analyser/
├── checklists/requirements.md
├── data-model.md
├── plan.md
├── quickstart.md
├── research.md
├── rulings/
│   ├── A-001-widen-deletion-sweep.md
│   └── Q-001-widen-deletion-sweep.md
├── spec.md
└── tasks.md
```

No external CLI or wire contract is introduced, so `contracts/` is
intentionally omitted.

### Live behavior and proof

```text
scripts/bootstrap-producer.sh
nix/
├── apps.nix
└── checks.nix
tests/
├── test-bootstrap-producer-canonical-cli.bats
├── test-bootstrap-producer-chain.bats
├── test-bootstrap-producer-history.bats
└── test-bootstrap-producer-sparse-boundaries.bats
justfile
.github/workflows/ci.yml
```

### Retired build and image surface

```text
amaru-bootstrap.cabal
app/header-extractor/                     # delete
lib/
├── AmaruBootstrap.hs                     # retain NodeConfig
└── HeaderExtractor.hs                    # delete
test/                                     # delete retired spec suite
nix/
├── apps.nix
├── bootstrap-producer-image.nix
├── checks.nix
└── header-extractor.nix                  # delete
flake.nix
justfile
.github/workflows/ci.yml
tests/
├── check-cli-mock-honesty.sh
├── lib/cli-mock-surface.bash
├── test-bootstrap-producer-canonical-cli.bats
└── test-header-extractor-cli.bats        # delete
```

### Current-facing documentation

```text
README.md
AGENTS.md
docs/
├── architecture.md
├── bootstrap-producer.md
└── index.md
skills/amaru-bootstrap-guide/SKILL.md
```

## Slice 1 - Derive and prove targets with db-analyser

**Risk tier**: specified integration coding. Driver effort: medium. Navigator
effort: xhigh.

**Owned files**:

- `scripts/bootstrap-producer.sh`
- `nix/apps.nix`
- target-extraction and runtime-input sections only in `nix/checks.nix`
- the point-check entry only in `justfile`
- the point-check entry only in `.github/workflows/ci.yml`
- `tests/test-bootstrap-producer-canonical-cli.bats`
- `tests/test-bootstrap-producer-chain.bats`
- `tests/test-bootstrap-producer-history.bats`
- `tests/test-bootstrap-producer-sparse-boundaries.bats`

**Forbidden scope**: the Haskell tool and its Cabal/Nix/image declarations;
CLI-mock-honesty declarations; current documentation; all historical specs and
docs; the constitution; dependency pins; `site/**`; `gate.sh`; this ticket's
Spec Kit artifacts; every other worktree.

**RED**:

- update the three success-capable producer fixtures to expose only strict
  `db-analyser` tip/trace behavior;
- add origin and malformed-trace assertions that fail against the current
  producer;
- replace the obsolete CLI check registration with an exact production-point
  assertion and its empty-array negative control;
- capture raw RED output before editing production behavior.

**GREEN**:

- the tip invocation has no analysis flag and includes minimum validation;
- `Point Origin` and unparseable successful output remain not ready;
- one trace pass writes `.logs/targets.json` with the exact three targets and
  three immediate parents;
- `preflight-blocks.json` no longer exists or has a consumer;
- staging targets, Amaru snapshot arguments, and era-history sidecars all
  consume the compact target records;
- `db-analyser-points`, shellcheck, producer bats, synthesized producer,
  Amaru startup, and both short-epoch checks pass;
- `./gate.sh` passes.

**Commit**: `refactor: derive snapshot targets with db-analyser`

**Trailer**: `Tasks: T001, T002, T003, T004, T005, T006, T007`

## Slice 2 - Remove the header-extractor build and image surface

**Risk tier**: specified deletion with broad build graph. Driver effort:
medium. Navigator effort: xhigh.

**Owned files**:

- `amaru-bootstrap.cabal`
- `app/header-extractor/Main.hs` (delete directory)
- `lib/HeaderExtractor.hs` (delete)
- `lib/AmaruBootstrap.hs`
- `test/HeaderExtractorSpec.hs` (delete)
- `test/Spec.hs` (delete)
- `tests/test-header-extractor-cli.bats` (delete)
- header-extractor portions only in
  `tests/test-bootstrap-producer-canonical-cli.bats`
- header-extractor portions only in `tests/check-cli-mock-honesty.sh`
- header-extractor portions only in `tests/lib/cli-mock-surface.bash`
- `nix/header-extractor.nix` (delete)
- header-extractor wiring only in `nix/apps.nix`
- header-extractor wiring only in `nix/bootstrap-producer-image.nix`
- header-extractor wiring only in `nix/checks.nix`
- header-extractor wiring only in `flake.nix`
- the retired spec-check entry only in `justfile`
- the retired spec-check entry only in `.github/workflows/ci.yml`

**Forbidden scope**: producer selection behavior from Slice 1; the retained
`db-analyser-points` check; current docs reserved for Slice 3; dependency pins
and hashes; unrelated flake/check structure; historical records; the
constitution; `site/**`; `gate.sh`; ticket Spec Kit artifacts; other
worktrees.

**RED**:

- the exact live build/config/test audit names every remaining retired surface;
- flake evaluation exposes the package, app, and spec check;
- image-layer inspection finds the executable.

**GREEN**:

- `NodeConfig` is exported from `AmaruBootstrap`, while `HeaderExtractor`, its
  CLI, and both suites no longer exist;
- Cabal retains only dependencies required by the marker/type module;
- no flake package, app, check, runtime input, image layer, CI entry, Just
  entry, or mock declaration exposes the executable;
- the exact live build/config/test audit is empty;
- image inspection finds zero executable paths;
- the focused checks, deterministic bundle comparison, and `./gate.sh` pass.

**Commit**: `refactor: remove header extractor build surface`

**Trailer**: `Tasks: T008, T009, T010, T011, T012, T013`

## Slice 3 - Align current-facing documentation

**Risk tier**: mechanical documentation alignment. Driver effort: low.
Navigator effort: xhigh.

**Owned files**:

- `README.md`
- `AGENTS.md` (`header-extractor` references only)
- `docs/index.md`
- `docs/architecture.md`
- `docs/bootstrap-producer.md`
- `skills/amaru-bootstrap-guide/SKILL.md` (`header-extractor` references only)

**Forbidden scope**: all source, build, test, and configuration files from
Slices 1-2; all `specs/00*`; `docs/history/**`; the constitution; the Amaru
pin; `site/**`; `gate.sh`; ticket Spec Kit artifacts; other worktrees.

**RED**: the current-facing documentation audit reports obsolete executable,
tip-info, list-blocks, and get-header references.

**GREEN**:

- current diagrams, prose, command lists, exit descriptions, AGENTS guidance,
  and the repository guide describe the stock `db-analyser` flow;
- no current-facing doc advertises the retired executable;
- `mkdocs build --strict`, the live-surface audit, and `./gate.sh` pass.

**Commit**: `docs: describe stock db-analyser producer flow`

**Trailer**: `Tasks: T014, T015, T016`

## Acceptance and Finalization

After each pair-approved commit, the ticket orchestrator independently reviews
the owned-file diff, checks the raw handoff evidence, reruns the focused proof
and `./gate.sh`, stamps the matching task boxes into the same commit, pushes,
and refreshes the human-facing PR body.

After Slice 3:

1. Re-run the exact six-point check and its negative control.
2. Re-run the deterministic 49-path/31-hash bundle comparison.
3. Inspect the producer image layers for executable absence.
4. Run the exact live-surface and historical-exception audits.
5. Run `./gate.sh`, including the Docker live boundary.
6. Run the commit/task finalization audit.
7. Drop `gate.sh`, push, refresh the technical evidence appendix, and mark PR
   #63 ready. Do not merge or close the issue.
