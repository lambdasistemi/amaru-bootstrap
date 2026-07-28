# Implementation Plan: Execute CLI Mock Honesty in the Build Gate

**Branch**: `fix/70-cli-mock-honesty-ci-wiring` | **Date**: 2026-07-28 |
**Spec**: [spec.md](spec.md)
**Input**: Feature specification from
`/specs/070-cli-mock-honesty-ci-wiring/spec.md`

## Summary

Add the existing CLI mock honesty flake check to the hosted and local explicit
Build Gate request lists. Prove the current lists are red from a reachability
perspective, prove the check itself rejects a seeded mock drift, then show the
two-line implementation makes the exact requested closure, local gate, full
live boundary, and hosted workflow green.

## Technical Context

**Language/Version**: GitHub Actions YAML; Just command recipes using Bash 5

**Primary Dependencies**: Nix flakes, the registered
`cli-mock-honesty` derivation, GitHub Actions, Just, Docker live verifier

**Storage**: No persistent application data; raw verification artifacts live
under the ticket runtime root

**Testing**: runtime RED assertion, exact Nix closure identity, seeded CLI
negative control, `just build-gate`, `nix flake check`, live Bats verifier,
and hosted pull-request checks/logs

**Target Platform**: x86_64 Linux on local Nix and self-hosted NixOS runners;
Docker for the live boundary

**Project Type**: Nix-first image build and test harness

**Performance Goals**: no runtime performance change; one additional existing
check joins the explicit shared-store warming build

**Constraints**: exactly two committed implementation files; no gate redesign,
Nix check change, mock/test change, dependency movement, or PR #69 overlap

**Scale/Scope**: one existing flake check added once to each of two command
lists

## Constitution Check

| Principle | Status | Evidence |
|---|---|---|
| I. No forks | PASS | No dependency or upstream source changes |
| II. Stock tools, custom orchestration | PASS | Only existing repository orchestration requests an existing stock-binary check |
| III. Reproducibility by SHA | PASS | No pin or image tag changes |
| IV. Nix-first | PASS | The flake check remains the invariant and both entry points request its exact attribute |
| V. Smallest provable step | PASS | Two list entries plus reachability and seeded-failure evidence |

Post-design check: PASS. The plan adds no new tool, abstraction, permanent test,
or moving reference.

## Boundary Review

The defect is at an orchestration seam: `nix/checks.nix` exports a correct
check, while the two user-facing explicit Build Gate consumers omit it.
Standalone flake success sees only the producer side of that seam. The closure
proof crosses it by resolving exactly what each Build Gate requests. Hosted log
evidence then proves GitHub Actions consumed the intended list, while the
existing live verifier preserves the node/producer/Amaru runtime boundary.

## Project Structure

### Documentation for this ticket

```text
specs/070-cli-mock-honesty-ci-wiring/
├── checklists/
│   └── requirements.md
├── plan.md
├── quickstart.md
├── research.md
├── spec.md
└── tasks.md
```

No data model, external interface contract, or agent-context technology update
is introduced, so `data-model.md`, `contracts/`, and an agent-context update
are intentionally omitted.

### Implementation surface

```text
.github/workflows/ci.yml
justfile
```

`tests/lib/cli-mock-surface.bash` may be mutated only as a temporary negative
control and must be restored exactly before implementation evidence. It is not
an owned implementation file.

## Slice 1 - Wire and falsify the explicit Build Gate

**Risk tier**: specified mechanical CI wiring. Driver is Codex at medium
reasoning; navigator is Claude Opus at high effort.

**Owned files**:

- `.github/workflows/ci.yml`
- `justfile`

**Evidence-only temporary surface**:

- `tests/lib/cli-mock-surface.bash` may receive the single authorized
  uncommitted rejected-command seed during RED only. It must be restored by
  inverse patch, hash-checked, and clean before the RED handoff.

**Forbidden scope**: `nix/checks.nix`, every other mock/test file, production
code, dependency manifests and locks, `gate.sh`, Spec Kit artifacts, PR
metadata, Git configuration, and every other worktree. Any need to change the
check, declarations, tests, pins, or additional files is a Q-file blocker and
plan amendment.

**RED**:

- write a runtime-only assertion that checks both explicit definitions and the
  exact requested closure;
- run it on the baseline and preserve its nonzero exit caused by both missing
  target entries;
- prove the closure instrument finds the standalone output but not the current
  explicit request closure;
- apply the one-off rejected accepted-command seed, require the standalone
  check to fail and name it, then restore the tracked file exactly;
- freeze the runtime assertion and raw outputs for navigator review without a
  committed repository test.

**GREEN**:

- add exactly one full target line to each owned file, preserving every other
  requested check;
- run the same runtime assertion and require structural counts plus exact
  closure reachability to pass;
- require the restored standalone check, `just build-gate`, and `./gate.sh` to
  exit zero;
- freeze complete post-edit evidence and owned-file hashes only after the final
  write;
- commit exactly the two owned files.

**Commit**: `fix(ci): execute CLI mock honesty in Build Gate`

**Trailer**:
`Tasks: T001, T002, T003, T004, T005, T006, T007, T008`

## Finalization - Publish hosted evidence (orchestrator-owned)

After accepting and pushing Slice 1, the ticket orchestrator stamps its tasks
into the implementation commit, refreshes the draft PR with a plain-language
landed chapter and technical evidence appendix, waits for both required hosted
checks, mechanically captures the Build Gate log proof, reruns the local gate
if any tracked byte changes, audits commit/task accounting, drops `gate.sh`,
marks PR #71 ready, appends `READY`, and hands back without merging.

## Complexity Tracking

No constitutional violation or complexity exception is required.
