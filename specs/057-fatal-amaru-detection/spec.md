# Feature Specification: Fatal Amaru Detection

**Feature Branch**: `fix/57-fatal-log-guard`  
**Created**: 2026-07-28  
**Status**: Ready for planning  
**Input**: GitHub issue
[`lambdasistemi/amaru-bootstrap#57`](https://github.com/lambdasistemi/amaru-bootstrap/issues/57),
with the live-boundary detail from superseded issue
[`#58`](https://github.com/lambdasistemi/amaru-bootstrap/issues/58)

## Context and Corrected Cause

The harness can report green while Amaru logs a fatal consensus event and
recovers without its container exiting. The repository already contains
fatal-log and early-exit helpers, but they have no reachable test path.

Git ancestry corrects the original issue narrative:

- commit
  [`2ece5d2`](https://github.com/lambdasistemi/amaru-bootstrap/commit/2ece5d2b3bbf7b9d9e309099f6a1738e911b92e0)
  introduced the helpers onto `main` without a caller;
- the intended peered live consume step exists at `87d916c` only on the
  unmerged `005-amaru-run-live-test` line and is not an ancestor of `main`;
- later producer and bare-main migrations preserved the dead state but did
  not remove a caller from `main`.

The systemic defect is therefore dead-on-arrival test code crossing a
worktree boundary without a reachability control. This feature builds the
live consume boundary against current contracts and adds the missing control.

The scored Antithesis property is tracked separately by
[`cardano-foundation/cardano-node-antithesis#193`](https://github.com/cardano-foundation/cardano-node-antithesis/issues/193).
That repository owns the deployed testnet and property harness, and its
tracer-sidecar currently does not ingest Amaru container stdout. The
downstream work must establish ingestion before scoring; it does not block
this repository's detector.

## User Scenarios & Testing

### User Story 1 - Fatal logs fail deterministically (Priority: P1)

As a maintainer, I can run a repository check and see a fatal Amaru log
rejected even when no process or container exit accompanies it.

**Why this priority**: The current green-board failure exists because exit
status is not a proxy for consensus health. A deterministic log contract is
the smallest proof that restores signal.

**Independent Test**: Run the log cleanliness check on a seeded log containing
the real `Consensus died, this should not happen!` signature and observe a
nonzero result with the `consensus` class. Run it on clean Amaru output and
observe success.

**Acceptance Scenarios**:

1. **Given** a log containing `Consensus died`, **when** the cleanliness
   check runs, **then** it fails and prints a bounded, labelled context block.
2. **Given** a log containing `roll back in the future`, **when** the check
   runs, **then** it fails as a distinct fatal class.
3. **Given** a log containing none of the fatal signatures, **when** the
   check runs, **then** it passes without a false fatal report.
4. **Given** any pre-existing fatal signature, **when** the check runs,
   **then** its existing class and diagnostic behavior remain covered.

---

### User Story 2 - The live verifier consumes the bundle (Priority: P1)

As a maintainer, I can run the existing Docker live verifier and know the
bundle was opened by the repository-pinned Amaru, peered with the live
cardano-node that supplied the ChainDB, and observed for a defined window.

**Why this priority**: Shape and startup-only checks cannot exercise header
validation against a real peer. The missing live boundary is where fatal
consensus events become observable.

**Independent Test**: Run the existing live verifier. It must use the same
cardano-node, ChainDB, producer image, and completed bundle; keep Amaru alive
and fatal-free for the configured window; and clean up all containers on
success or failure.

**Acceptance Scenarios**:

1. **Given** a produced bundle and its live source node, **when** the consume
   phase starts, **then** Amaru runs with the current `node run` interface and
   peers with that node.
2. **Given** Amaru emits a fatal signature during the hold window, **when**
   the verifier observes it, **then** the verifier fails even if the container
   remains running.
3. **Given** Amaru exits before the hold window ends, including exit code
   zero, **when** liveness is checked, **then** the verifier fails with the
   bounded tail of the Amaru log.
4. **Given** Amaru stays alive and emits no fatal signature for the full
   window, **when** the phase completes, **then** the verifier passes and
   reports the observed duration.

---

### User Story 3 - Dead test helpers cannot land silently (Priority: P2)

As a maintainer, I can run the flake checks and know that a helper declared
under `tests/lib/` has a reachable caller or an explicit, reviewable exemption.

**Why this priority**: The fatal scanner was born orphaned on `main`. A caller
fix without a recurrence control leaves the actual integration failure intact.

**Independent Test**: Add an uncalled helper to a temporary test-library
fixture and observe the reachability audit fail. Add a real caller and observe
it pass.

**Acceptance Scenarios**:

1. **Given** an uncalled test helper, **when** the reachability audit runs,
   **then** it fails and names the helper.
2. **Given** each discovered test helper has a caller or explicit exemption,
   **when** the audit runs, **then** it passes.
3. **Given** the complete ticket change, **when** the flake checks run,
   **then** the reachability audit is included in the result.

### Edge Cases

- Multiple fatal signatures may occur in one log; diagnostics remain bounded
  and deterministic rather than dumping an unbounded run log.
- A fatal signature can appear before, during, or after Amaru reports startup;
  the hold-window scan must not depend only on a positive startup marker.
- A clean process exit before the hold window is still a failure.
- Missing or unreadable log files must not be interpreted as clean logs.
- Live-verifier prerequisites continue to skip the test as a unit; the consume
  phase must not run partially when Docker or required images are unavailable.
- A reachability audit must distinguish function declarations from call sites
  and provide an explicit path for intentionally exported or indirect helpers.

## Requirements

### Functional Requirements

- **FR-001**: The repository MUST expose one log cleanliness check that returns
  failure when a configured fatal Amaru signature is present and success only
  when the log is readable and clean.
- **FR-002**: Fatal signatures MUST include `Invalid VRF proof`,
  `Consensus died`, `HeaderValidationError`, `ledger inconsistency`, and
  `roll back in the future`.
- **FR-003**: Each fatal match MUST emit a stable class label plus a bounded
  context block suitable for CI triage.
- **FR-004**: The deterministic check MUST demonstrate both directions using
  the real `Consensus died` text: seeded fatal input fails; clean input passes.
- **FR-005**: The existing Docker live verifier MUST consume the bundle with
  the repository-pinned Amaru using the current `node run` contract.
- **FR-006**: The live Amaru process MUST peer with the cardano-node instance
  that supplied the ChainDB used by the producer.
- **FR-007**: The verifier MUST observe Amaru for a positive, configurable hold
  window and fail promptly on a fatal signature or early exit of any code.
- **FR-008**: Pass, fatal, and early-exit paths MUST clean up every process,
  container, and temporary artifact introduced by the consume phase.
- **FR-009**: A repository-level audit MUST fail when a helper under
  `tests/lib/` has no caller and no explicit exemption.
- **FR-010**: The deterministic fatal-log and helper-reachability proofs MUST
  be wired into Nix flake checks.
- **FR-011**: The Docker live verification path MUST remain part of the full
  local CI mirror.
- **FR-012**: Producer behavior and the emitted bundle MUST remain unchanged.
- **FR-013**: No upstream fork, dependency pin, or upstream Amaru behavior
  change may be introduced.

## Success Criteria

### Measurable Outcomes

- **SC-001**: A seeded log containing the issue's real `Consensus died`
  signature produces a nonzero cleanliness result and a `consensus` diagnostic.
- **SC-002**: The same cleanliness check returns zero on clean input.
- **SC-003**: All five fatal signatures have deterministic class coverage,
  including the new future-rollback signature.
- **SC-004**: The live verifier observes one Amaru instance against one live
  source cardano-node for the entire configured hold window or fails with a
  classified diagnostic.
- **SC-005**: An uncalled helper fixture makes the reachability audit fail, and
  the repository's real helper set makes it pass.
- **SC-006**: `nix flake check` and the full local CI mirror complete
  successfully after implementation.
- **SC-007**: No file outside `tests/`, localized `nix/checks.nix` wiring,
  this feature's `specs/` artifacts, and the temporary ticket `gate.sh`
  changes.

## Assumptions

- The already-loaded producer image contains the exact SHA-pinned Amaru binary
  the live verifier should exercise, so the consume boundary does not require
  a host-installed Amaru.
- The prior unmerged live test is a behavioral reference only; current command
  and bundle contracts are derived from `main`.
- The downstream scored property is independently owned by
  `cardano-node-antithesis#193` and is not an acceptance dependency for this
  pull request.
- Sibling PR #56 may land before the helper-reachability slice. If it does,
  this ticket reuses its check seam where practical; otherwise the audit stays
  standalone and exposes an obvious extension point.

