# Implementation Plan: Fatal Amaru Detection

**Branch**: `fix/57-fatal-log-guard` | **Date**: 2026-07-28 |
**Spec**: [spec.md](spec.md)  
**Input**: Feature specification from
`/specs/057-fatal-amaru-detection/spec.md`

## Summary

Turn the existing fatal scanner into one caller-facing cleanliness contract,
prove it directly on seeded fatal and clean logs, and wire those tests into the
CI-built `bootstrap-producer-bats` flake check. Extend the existing Docker live
verifier to run the producer image's pinned Amaru against the live source node,
polling both logs and liveness for a configured hold window. Finish with a
test-helper reachability audit inside the existing `cli-mock-honesty` check
landed by sibling issue #51.

The corrected ancestry and detailed decisions are in
[research.md](research.md). The exact log behavior is frozen in
[contracts/fatal-log-contract.md](contracts/fatal-log-contract.md).

## Technical Context

**Language/Version**: Bash 5 and Bats  
**Primary Dependencies**: Existing Nix-pinned Amaru producer image,
cardano-node 10.7.1 image, Docker, coreutils, grep  
**Storage**: Temporary ChainDB, bundle, container log, and RocksDB stores  
**Testing**: Bats, existing `bootstrap-producer-bats` flake check, Docker live
verifier, `nix flake check`, and `just ci`  
**Target Platform**: x86_64 Linux on self-hosted NixOS runners with Docker  
**Project Type**: Test harness and Nix check  
**Performance Goals**: Fatal or early-exit live failures surface on the next
short poll; clean runs complete one configurable hold window  
**Constraints**: `tests/` plus localized `nix/checks.nix`; no production,
workflow, justfile, dependency, pin, or upstream changes  
**Scale/Scope**: Five fatal signatures, one live node, one producer, one Amaru
consumer, and the repository's Bash test-helper library

## Constitution Check

- **No forks**: Pass. The live check uses the Amaru binary already pinned in
  the producer image.
- **Stock tools**: Pass. Docker orchestrates stock cardano-node and the existing
  producer image; no upstream behavior is reimplemented.
- **Pin by SHA**: Pass. No input, lock, or image-reference pin changes.
- **Nix-first**: Pass. Deterministic fatal proofs run inside
  `bootstrap-producer-bats`; the reachability proof extends the already
  registered `cli-mock-honesty` flake check.
- **Smallest provable step**: Pass. The fatal contract lands before the live
  boundary, and both precede the generalized recurrence control.
- **Bundle output contract**: Pass by construction. Producer code and bundle
  creation are unchanged; final verification still runs the full local CI
  mirror.
- **Evidence over assumption**: Pass. The seeded fatal and clean commands are
  run directly, and the live boundary is observed rather than inferred from
  container status.

## Design

### Shared cleanliness contract

`tests/lib/bootstrap-helpers.bash` keeps the fatal class table in one place and
exposes a cleanliness function with ordinary shell semantics: zero means
readable and clean; nonzero means fatal or unreadable. The existing scanner
continues to own bounded class diagnostics.

`tests/test-bootstrap-helpers.bats` covers all five classes, missing/unreadable
input, clean input, and the direct check semantics. `nix/checks.nix` adds this
suite to `bootstrap-producer-bats`, which the required Build Gate already
builds.

### Containerized live consumer

`tests/test-bootstrap-producer-live.bats` reuses its node, synthesized ChainDB,
producer image, and bundle. It starts the image a second time with the Amaru
entrypoint and current `node run` arguments, sharing the node container's
network namespace so `127.0.0.1:3001` is the real source peer.

The live loop refreshes `docker logs`, applies the shared cleanliness check,
then verifies the container remains running. Teardown removes the consumer on
every path. A reproduced upstream #1095 signature remains a real failure; no
whitelist is introduced.

### Test-helper reachability in `cli-mock-honesty`

Sibling issue #51 / PR #56 has landed
`tests/check-cli-mock-honesty.sh`, its shared declarations in
`tests/lib/cli-mock-surface.bash`, and the registered `cli-mock-honesty` flake
check. Extend that mechanism in place: discover Bash helper declarations under
`tests/lib/`, distinguish declarations/comments from call sites, and require
either a reachable call or an explicit exemption.

The existing script owns its own positive and negative controls. Add an
uncalled fixture that must be rejected and named, plus reachable and explicitly
exempt fixtures that must pass, before auditing the real helper tree. This
mirrors #51's real-path/removed-path controls and prevents an auditor that
always returns success from passing. Do not add a second checker, Bats suite, or
flake output.

## Project Structure

```text
specs/057-fatal-amaru-detection/
├── checklists/requirements.md
├── contracts/fatal-log-contract.md
├── plan.md
├── quickstart.md
├── research.md
├── spec.md
└── tasks.md
tests/
├── check-cli-mock-honesty.sh
├── lib/
│   ├── bootstrap-helpers.bash
│   └── cli-mock-surface.bash
├── test-bootstrap-helpers.bats
└── test-bootstrap-producer-live.bats
nix/
└── checks.nix
```

**Structure Decision**: Behavior and audits remain in `tests/`; Nix only
publishes them through an existing CI-built check. The Docker live path stays
in its current suite and full CI recipe.

## Slice Plan

### Slice 1 - Freeze and prove fatal-log cleanliness

Add the future-rollback class and the caller-facing cleanliness function. Add
deterministic tests for all five classes and clean/missing input, then wire the
suite into `bootstrap-producer-bats`.

**Owned files**:

- `tests/lib/bootstrap-helpers.bash`
- `tests/test-bootstrap-helpers.bats`
- `nix/checks.nix`

**RED/GREEN proof**:

- RED: the new future-rollback and cleanliness tests fail before
  implementation.
- Required direct evidence after the final edit: the exact cleanliness check
  exits nonzero on a seeded real `Consensus died` line and zero on clean input.
- GREEN: `nix build .#checks.x86_64-linux.bootstrap-producer-bats`.

**Commit**: `test: fail on fatal Amaru log events`  
**Trailer**: `Tasks: T001, T002, T003, T004, T005`

### Slice 2 - Build the peered live consume boundary

Run the pinned Amaru from the producer image against the completed bundle and
the live source node. Observe fatal logs and early exits continuously for the
hold window and clean up on every path.

**Owned files**:

- `tests/lib/bootstrap-helpers.bash`
- `tests/test-bootstrap-producer-live.bats`

**RED/GREEN proof**:

- RED: the existing live suite has no Amaru consumer and therefore cannot
  satisfy the new consume-boundary assertions.
- GREEN: `just live-bootstrap-producer`, followed by `./gate.sh`.
- Negative proof: seed or inject a fatal line through the test seam and show
  the live cleanliness path fails without depending on container exit.

**Commit**: `test: restore live Amaru bundle consumption`  
**Trailer**: `Tasks: T006, T007, T008, T009, T010`

### Slice 3 - Extend `cli-mock-honesty` with helper reachability

Extend sibling #51's landed checker with declaration, call-site, and explicit
exemption handling. Run its positive and negative fixture controls, then audit
the real `tests/lib/` tree through the existing `cli-mock-honesty` flake output.

**Owned files**:

- `tests/check-cli-mock-honesty.sh`
- `tests/lib/cli-mock-surface.bash`
- `nix/checks.nix` only if the existing check needs another runtime input

**RED/GREEN proof**:

- RED: the existing check fails when asked to audit an uncalled fixture and
  names the helper.
- GREEN: the uncalled negative control is still rejected, while reachable,
  explicitly exempt, and repository-tree controls pass.
- Focused gate:
  `nix build .#checks.x86_64-linux.cli-mock-honesty`.

**Commit**: `test: reject unreachable test helpers`  
**Trailer**: `Tasks: T011, T012, T013, T014`

### Slice 4 - Publish evidence (orchestrator-owned)

Update PR #59 after every implementation push, close task accounting, inspect
the parent inbox, run `just ci`, run the final commit/task audit, and remove
`gate.sh` before marking the PR ready. No worker edits this metadata slice.

## Final Verification

```text
nix build .#checks.x86_64-linux.bootstrap-producer-bats
nix build .#checks.x86_64-linux.cli-mock-honesty
nix flake check
just live-bootstrap-producer
just ci
```

The final review also confirms no producer file changed and the feature's
owned-file boundary contains the entire branch diff.

## Complexity Tracking

No constitutional violation or complexity exception is required.
