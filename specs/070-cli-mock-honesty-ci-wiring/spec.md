# Feature Specification: Execute CLI Mock Honesty in the Build Gate

**Feature Branch**: `fix/70-cli-mock-honesty-ci-wiring`
**Created**: 2026-07-28
**Status**: Ready for planning
**Input**: GitHub issue
[`lambdasistemi/amaru-bootstrap#70`](https://github.com/lambdasistemi/amaru-bootstrap/issues/70)

## User Scenarios & Testing

### User Story 1 - Detect mocked CLI drift at the repository gate (Priority: P1)

As a repository maintainer, I can run either the local Build Gate or the
hosted Build Gate and know that both execute the existing CLI mock honesty
check, so a mock that accepts a command rejected by the pinned real binary
blocks the change.

**Why this priority**: A registered check that neither normal entry point
requests is operationally inert. Maintainers currently receive a green Build
Gate even when this declared-versus-real command contract could be red.

**Independent Test**: Resolve the full closure of the exact checks requested
by the Build Gate and confirm it contains the CLI mock honesty output. Seed
one rejected command into the accepted mock surface, observe the wired check
fail, restore the tree, and observe both entry points and the full live gate
pass.

**Acceptance Scenarios**:

1. **Given** the hosted Build Gate command, **when** its explicit check list is
   inspected and built, **then** it directly requests the CLI mock honesty
   check.
2. **Given** the local `build-gate` recipe, **when** its explicit check list is
   inspected and built, **then** it requests the same CLI mock honesty check.
3. **Given** a one-off accepted-command declaration that the pinned real
   binary rejects, **when** the wired check runs, **then** it exits nonzero and
   names the rejected command.
4. **Given** the temporary drift is fully restored, **when** the local full
   gate and hosted pull-request workflow run, **then** the build and live
   boundary checks succeed.

### Edge Cases

- A standalone check can pass while remaining absent from both normal entry
  points. Standalone success alone is not acceptance evidence.
- Shared dependencies can appear in an explicit check set's closure without
  proving the named check output is reachable. The proof matches the exact
  CLI mock honesty output path.
- The two explicit lists can drift independently. The change must place the
  same flake attribute in both lists and preserve their existing order.
- The seeded mock drift is evidence only. It must remain uncommitted and the
  tracked test surface must be byte-for-byte restored before GREEN evidence.
- The full flake suite already reaches the check, so the ticket must prove the
  narrower `build-gate` entry point rather than relying on `nix flake check`.
- Pull request #69 changes dependency-pin surfaces only. This ticket must not
  absorb, revert, or rebase those in-flight changes unless GitHub later
  reports that an actual rebase is required.

## Requirements

### Functional Requirements

- **FR-001**: The hosted `Build Gate` command MUST explicitly request
  `.#checks.x86_64-linux.cli-mock-honesty`.
- **FR-002**: The local `build-gate` recipe MUST explicitly request the same
  flake check.
- **FR-003**: The hosted and local explicit check lists MUST otherwise remain
  unchanged.
- **FR-004**: Fresh recursive closure evidence for the final explicit request
  set MUST contain the evaluated CLI mock honesty output path.
- **FR-005**: The closure instrument MUST have a positive control proving it
  can find that output when directly requested.
- **FR-006**: A one-off uncommitted accepted-command drift MUST make the CLI
  mock honesty check exit nonzero against the pinned real binary.
- **FR-007**: The drifted test file MUST be restored exactly before the final
  diff, pass evidence, or commit is captured.
- **FR-008**: The existing CLI mock honesty implementation, accepted command
  declarations, test doubles, tests, Nix check registration, and dependency
  pins MUST remain unchanged in the committed result.
- **FR-009**: The final committed tree MUST pass the complete repository gate,
  including the live cardano-node-to-Amaru boundary.
- **FR-010**: Pull-request checks named `Build Gate` and
  `Live Bootstrap Producer` MUST conclude successfully, and hosted Build Gate
  logs MUST contain the requested CLI mock honesty attribute.
- **FR-011**: Exact commands, raw outputs, exit codes, and post-restore hashes
  MUST be captured sequentially under the ticket runtime root.
- **FR-012**: The implementation diff MUST contain no behavior-changing files
  beyond `.github/workflows/ci.yml` and `justfile`.

## Success Criteria

### Measurable Outcomes

- **SC-001**: Both explicit Build Gate definitions contain exactly one request
  for `.#checks.x86_64-linux.cli-mock-honesty`.
- **SC-002**: The final explicit request closure contains exactly the evaluated
  CLI mock honesty output path, while the preserved baseline evidence shows it
  was absent before the wiring change.
- **SC-003**: The seeded rejected command produces a nonzero check exit and the
  restored source produces a zero exit without a committed test-surface diff.
- **SC-004**: `just build-gate` and the complete local gate both exit 0 on the
  final committed tree.
- **SC-005**: Both required hosted checks conclude success on the final reviewed
  commit, and the Build Gate log contains the full CLI mock honesty target.
- **SC-006**: The implementation commit changes exactly two files and contains
  zero changes to Nix definitions, dependency locks, mocks, tests, or
  production code.

## Assumptions

- The existing `cli-mock-honesty` flake check remains the source of truth for
  comparing accepted mock command paths with the pinned real binary.
- The repository intentionally maintains explicit Build Gate lists; redesigning
  that mechanism is outside this ticket.
- x86_64 Linux, Nix, the self-hosted NixOS runner, and a Docker daemon are
  available to the existing verification commands.
- Pull request #69 remains disjoint at dispatch time. Merge order is
  unconstrained unless the second pull request to land later requires a rebase.
