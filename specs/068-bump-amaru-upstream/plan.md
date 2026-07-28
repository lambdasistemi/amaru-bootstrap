# Implementation Plan: Bump Amaru to Upstream Main

**Branch**: `chore/bump-amaru-pin-upstream-main` | **Date**: 2026-07-28 |
**Spec**: [spec.md](spec.md)
**Input**: Feature specification from
`/specs/068-bump-amaru-upstream/spec.md`

## Summary

Freeze the execution-time stock `pragma-org/amaru` main SHA, update only
the Amaru flake declaration and lock node, and use the existing
declared-vs-real CLI invariant plus the full build and Docker boundary gate
to prove compatibility. If the selected binary rejects an accepted mock
command, reconcile only the explicitly fenced CLI declaration and tests.

## Technical Context

**Language/Version**: Nix flake lock format; Bash 5 verification helpers

**Primary Dependencies**: stock `pragma-org/amaru` non-flake input, Nix,
the existing `cli-mock-honesty` check, Docker live verifier

**Storage**: Nix source lock metadata only

**Testing**: exact pin assertions, structural lock isolation, seeded CLI
negative control, `cli-mock-honesty`, `nix flake check`, Build Gate, and
the live producer/consumer Bats verifier

**Target Platform**: x86_64 Linux under Nix; Docker for the live boundary

**Project Type**: Nix-first supplier image and test harness

**Performance Goals**: no runtime performance change is claimed; existing
build and 60-second live observation remain within their current gates

**Constraints**: exact SHA pin, no fork or moving ref, no unrelated lock
movement, no compose edit, no consensus fix, no weakened test surface

**Scale/Scope**: one dependency input, one lock node, and conditional
reconciliation of the already-declared Amaru mock/test surface

## Constitution Check

| Principle | Status | Evidence |
|---|---|---|
| I. No forks | PASS | Source remains bare `pragma-org/amaru`; no patch or vendoring is allowed |
| II. Stock tools, custom orchestration | PASS | The repository consumes the unmodified upstream binary and changes only orchestration metadata/tests |
| III. Reproducibility by SHA | PASS | The execution-time main commit is frozen to one full SHA in the declaration and lock |
| IV. Nix-first | PASS | Nix refreshes lock metadata and all compatibility/build proofs are flake gates |
| V. Smallest provable step | PASS | One vertical pin-and-proof slice; conditional test reconciliation occurs only on real-binary evidence |

Post-design check: PASS. No fork, new tool, schema, runtime abstraction, or
unpinned input is introduced.

## Boundary Review

The changed boundary is a newly selected upstream Amaru binary consuming
the bootstrap bundle produced while cardano-node holds its ChainDB open.
`cli-mock-honesty` proves the declared command seam, but only
`just live-bootstrap-producer` crosses the filesystem, container,
producer, and Amaru consumer seam. `gate.sh` retains both classes of proof.

## Project Structure

### Documentation for this ticket

```text
specs/068-bump-amaru-upstream/
├── checklists/
│   └── requirements.md
├── plan.md
├── quickstart.md
├── research.md
├── spec.md
└── tasks.md
```

No data model, external interface contract, or agent-context technology
update is introduced, so `data-model.md`, `contracts/`, and the
agent-context update are intentionally omitted.

### Implementation and conditional compatibility surface

```text
flake.nix
flake.lock
tests/
├── check-cli-mock-honesty.sh
├── lib/
│   └── cli-mock-surface.bash
├── test-amaru-relay-bootstrap.bats
├── test-bootstrap-producer-canonical-cli.bats
├── test-bootstrap-producer-history.bats
├── test-bootstrap-producer-sparse-boundaries.bats
└── test-relay-entrypoint.bats
```

## Slice 1 - Repin Amaru and prove the real surface

**Risk tier**: specified dependency pin with conditional test-surface
reconciliation. Qwen driver uses the operator-selected
`qwen3.8-max-preview`; navigator is Claude Opus at `xhigh`.

**Owned files**:

- `flake.nix`
- `flake.lock`
- `tests/lib/cli-mock-surface.bash` only if the real binary rejects a
  currently declared command
- `tests/check-cli-mock-honesty.sh` only if the real binary proves its
  acceptance/rejection probe must change
- `tests/test-bootstrap-producer-canonical-cli.bats` only for a
  corresponding declared-surface reconciliation
- `tests/test-bootstrap-producer-history.bats` only for a corresponding
  declared-surface reconciliation
- `tests/test-bootstrap-producer-sparse-boundaries.bats` only for a
  corresponding declared-surface reconciliation
- `tests/test-amaru-relay-bootstrap.bats` only for a corresponding
  declared-surface reconciliation
- `tests/test-relay-entrypoint.bats` only for a corresponding
  declared-surface reconciliation

**Forbidden scope**: production scripts, Nix package/image/check
definitions, `gate.sh`, all Spec Kit artifacts, documentation, dependency
manifests other than the two named flake files, other lock nodes, upstream
code, compose files, `.github/`, Git configuration, and every other
worktree. Any real-binary failure requiring production or build-definition
changes is a Q-file blocker and plan amendment.

**RED**:

- capture upstream main and open/merged state for `pragma-org/amaru#1098`;
- stop if the expected-red premise changed;
- prove the old source and lock revisions do not equal the captured target;
- seed one rejected command in the accepted mock surface, run
  `cli-mock-honesty`, and preserve its nonzero raw output;
- restore the seed before the final pin edit.

**GREEN**:

- `flake.nix` and `.nodes.amaru` in `flake.lock` resolve to the captured
  full SHA;
- lock JSON with `.nodes.amaru` removed matches the baseline exactly;
- any CLI-surface edit is justified by raw failure from the selected real
  binary, remains fail-closed, and contains no compatibility guess;
- the exact-pin assertion, CLI honesty check, Build Gate, and
  `./gate.sh` all exit zero with raw evidence captured sequentially;
- final file and handoff hashes are captured only after the last edit.

**Commit**: `build: bump amaru to upstream main`

**Trailer**: `Tasks: T001, T002, T003, T004, T005, T006, T007`

## Finalization - Publish evidence (orchestrator-owned)

After accepting and pushing Slice 1, the ticket orchestrator stamps its
tasks into the same implementation commit, updates the draft PR with a
plain-language landed chapter and technical evidence appendix, reruns the
full gate and commit audit, waits for both named hosted checks, drops
`gate.sh`, and marks PR #69 ready. The orchestrator does not merge.

## Complexity Tracking

No constitutional violation or complexity exception is required.
