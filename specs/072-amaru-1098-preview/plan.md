# Implementation Plan: Preview the Amaru #1098 Fix Head

**Branch**: `chore/72-preview-amaru-1098`  
**Date**: 2026-07-29  
**Spec**: [spec.md](spec.md)  
**Issue**: #72  
**Pull Request**: #73 (draft, PREVIEW / DO NOT MERGE)

## Summary

Select the immutable execution-time head of the open Amaru #1098 pull
request on one disposable preview branch, prove the existing offline
peer-snapshot staging and real CLI surface against it, run the complete
local and hosted gates, then report the published immutable PR image tag
and digest. The branch remains draft and open forever; it is not an
upstream-main adoption.

## Technical Context

**Language/Version**: Nix flake metadata; upstream Rust built with Amaru's
`rust-toolchain.toml`  
**Primary Dependencies**: `pragma-org/amaru` at one full commit SHA,
crane, rust-overlay  
**Storage**: Nix lock metadata and GHCR image manifests  
**Testing**: exact-pin assertion, unrelated-lock structural comparison,
`cli-mock-honesty`, `just build-gate`, Docker live verifier, hosted CI  
**Target Platform**: x86_64-linux and the repository's self-hosted NixOS
runner  
**Project Type**: Nix-first image producer  
**Performance Goal**: one live consumer observation held for at least
60 seconds  
**Constraints**: no upstream fork/patch/vendor; no moving dependency or
image tag; non-main source confined to a never-merge draft branch  
**Scale/Scope**: one dependency input, one reviewed implementation commit,
one published PR image

## Constitution Check

### Before design

- **I. No Forks**: PASS. The preview consumes an unmodified upstream commit.
- **II. Stock Tools, Custom Orchestration**: PASS. No Amaru source change is
  planned; consumer adaptation requires raw failure and a plan amendment.
- **III. Reproducibility By Pinning**: PASS. Source and image identities are
  immutable SHAs/digests.
- **IV. Nix-First**: PASS. The existing flake, checks, image derivation, and
  NixOS CI path remain authoritative.
- **V. Smallest Provable Step**: PASS. Exact-pin RED, seeded CLI RED, focused
  build, and live boundary precede publication.

### Preview guard

The target is a non-main upstream reference and has diverged from the
currently selected upstream-main revision. This is permitted only because
PR #73 is explicitly PREVIEW / DO NOT MERGE and remains draft. Any request
to land this source on repository main is a stop-and-escalate event.

### After design

PASS. No constitutional exception is required. The preview's non-main
source is quarantined by branch/PR lifecycle rather than normalized into
the repository's mainline dependency policy.

## Project Structure

```text
flake.nix
flake.lock
nix/amaru.nix
tests/lib/cli-mock-surface.bash
specs/072-amaru-1098-preview/
├── checklists/requirements.md
├── plan.md
├── quickstart.md
├── research.md
├── spec.md
└── tasks.md
```

`nix/amaru.nix` is read-only in the planned slice. If the real selected
source proves that adaptation is required, the driver writes a Q-file and
the orchestrator amends the plan and owned-file fence before a fresh slice.

No data model or external interface contract is introduced. The relevant
contract is the existing flake input, CLI honesty check, live bundle
boundary, and PR-image workflow.

## Phase 0 - Research

- Freeze the initial #1098 source identity and divergence from the current
  pin.
- Compare the changed upstream files and peer-snapshot build contract.
- Confirm the existing same-repository PR image publication path and tag
  shape.
- Define force-push, gate-failure, and publication escalation conditions.

Output: [research.md](research.md)

## Phase 1 - Design and verification contract

- Specify the exact pin and unrelated-lock invariants.
- Specify a seeded negative control for the real command-surface check.
- Keep consumer adaptation behind raw failure and an amended owned-file
  fence.
- Define local gate, hosted checks, registry digest, and draft-parking
  evidence.

Output: [quickstart.md](quickstart.md)

Agent context update is intentionally skipped: the plan adds no language,
tool, framework, or repository convention absent from AGENTS.md.

## Slice 1 - Pin and prove the preview source

**Owner**: qwen driver + navigator pair  
**Effort**: specified mechanical dependency work; qwen max driver,
high-effort navigator  
**Owned files**:

- `flake.nix`
- `flake.lock`
- `tests/lib/cli-mock-surface.bash` (temporary RED seed only; no final diff
  unless the real target proves a surface change)

**Read-only evidence inputs**:

- `nix/amaru.nix`
- `.github/workflows/ci.yml`
- `.github/workflows/publish-bootstrap-image.yml`

**Forbidden scope**: `gate.sh`, specs, docs, `.github/`, every other lock
node, upstream source, Git configuration, pushes, and every other worktree.
Any required edit outside the owned files is a Q-file blocker and plan
amendment.

**RED**:

- re-resolve the upstream branch and require the observed SHA to equal the
  brief target;
- prove the current source and lock revisions do not equal that target;
- temporarily add one invalid accepted Amaru command and require
  `cli-mock-honesty` to exit nonzero;
- freeze the complete RED diff and evidence, obtain navigator approval, and
  restore only the temporary seed.

**GREEN**:

- update the full source SHA and only the Amaru lock node;
- prove every unrelated lock node is unchanged;
- require `cli-mock-honesty`, `just build-gate`, and `./gate.sh` to exit
  zero;
- prove `nix/amaru.nix` remained unchanged and its staged peer snapshots
  sufficed;
- recheck the upstream branch head, capture frozen diff/hashes
  sequentially, and obtain navigator approval.

**Commit**: `build: pin amaru to #1098 preview head`

**Trailer**: `Tasks: T001, T002, T003, T004, T005, T006, T007`

## Slice 2 - Publish and park evidence (orchestrator-owned)

After accepting Slice 1, the ticket orchestrator stamps task completion
into the reviewed commit, pushes, refreshes the human-readable PR body,
verifies both hosted checks on that commit, waits for the existing image
publisher, resolves the immutable `pr-73-<sha>` tag to a registry digest,
records and reports the evidence, and parks the PR open in draft state.

`gate.sh` remains present because the PR is intentionally not finalized or
marked ready.

## Complexity Tracking

No source patch, fork, vendoring, new publisher, or persistent exception is
authorized. A consumer adaptation discovered by the gate requires a plan
amendment and a fresh paired slice.
