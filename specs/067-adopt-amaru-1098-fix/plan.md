# Implementation Plan: Adopt the Amaru Consensus Fix

**Branch**: `chore/67-adopt-amaru-1098-fix` | **Date**: 2026-07-29 |
**Spec**: [spec.md](spec.md)

## Summary

Freeze a bare upstream-main Amaru revision containing #1098, update only
the declaration and Amaru lock node, and prove the selected squash tree
through the permanent CLI, Build Gate, and Docker live-boundary checks.
Publish the successful PR image by commit tag and digest, then ask the
milestone desk for merge authorization.

## Technical Context

**Dependencies**: stock `pragma-org/amaru` non-flake input, Nix, Docker

**Testing**: exact pin/ancestry assertions, structural lock isolation,
seeded CLI negative control, `cli-mock-honesty`, `just build-gate`,
`./gate.sh`, hosted checks, and registry inspection

**Constraints**: one implementation commit; exact SHA; no fork, patch,
moving ref, unrelated lock update, assertion weakening, or premature
Antithesis claim

## Constitution Check

| Principle | Status | Evidence |
|---|---|---|
| I. No forks | PASS | Bare stock `pragma-org/amaru` only |
| II. Stock tools, custom orchestration | PASS | Existing upstream binary and repository harness |
| III. Reproducibility by SHA | PASS | One captured full main SHA in source and lock |
| IV. Nix-first | PASS | Nix refresh and flake-owned gates |
| V. Smallest provable step | PASS | One dependency pin plus existing proofs |

Post-design check: PASS. No constitutional exception is required.

## Boundary Review

The selected upstream binary crosses two load-bearing boundaries: the
declared command surface and the bundle consumed while cardano-node holds
its ChainDB open. `cli-mock-honesty` proves the former; only the full Docker
live verifier proves the latter. Registry inspection then proves the
artifact handed downstream is the hosted result for the reviewed commit.

## Project Structure

```text
specs/067-adopt-amaru-1098-fix/
├── checklists/requirements.md
├── plan.md
├── quickstart.md
├── research.md
├── spec.md
└── tasks.md

flake.nix
flake.lock
```

`tests/lib/cli-mock-surface.bash` is temporary RED-seed scope only.
`nix/amaru.nix` is read-only unless a selected-source failure is raised and
the plan is amended.

## Slice 1 - Pin and prove

**Pair**: Qwen driver (`qwen3.8-max-preview`) and Claude Opus navigator
(high effort).

**Owned files**:

- `flake.nix`
- `flake.lock`
- `tests/lib/cli-mock-surface.bash` for the temporary RED seed only

**Forbidden**: `nix/amaru.nix`, production/test behavior, other lock nodes,
specs, gate, workflows, compose, upstream source, and every other worktree.
Any need outside owned scope is a Q-file blocker.

**RED**:

- freeze upstream main and prove it contains `437ff6c4`;
- prove old declaration and lock revisions differ from the target;
- seed a known rejected command, capture nonzero `cli-mock-honesty`, and
  obtain navigator approval before pin edits.

**GREEN**:

- explicitly restore the seed;
- update both dependency records to the frozen SHA;
- prove every unrelated lock node and `nix/amaru.nix` are unchanged;
- pass selected-source CLI honesty, `just build-gate`, and `./gate.sh`;
- freeze final diff/hashes and obtain navigator approval.

**Commit**: `build: adopt amaru consensus fix`

**Trailer**: `Tasks: T001, T002, T003, T004, T005, T006`

## Slice 2 - Publish evidence

The orchestrator pushes the reviewed implementation commit, waits for
`Build Gate` and `Live Bootstrap Producer`, inspects
`ghcr.io/lambdasistemi/amaru-bootstrap-producer:pr-74-<commit-sha>`, records
its digest in the PR, reruns the mechanical audits, and posts a
merge-authorization Q-file to the milestone desk. It does not merge or
claim the Antithesis payoff.

## Complexity Tracking

No violation or complexity exception is required.
