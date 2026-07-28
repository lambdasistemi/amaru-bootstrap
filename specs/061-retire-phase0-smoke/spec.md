# Feature Specification: Retire Obsolete Phase-0 Smoke

**Feature Branch**: `fix/61-phase-0-smoke-verdict`  
**Created**: 2026-07-28  
**Status**: Ready for planning  
**Input**: GitHub issue
[`lambdasistemi/amaru-bootstrap#61`](https://github.com/lambdasistemi/amaru-bootstrap/issues/61)

## User Scenarios & Testing

### User Story 1 - Trust the repository's green checks (Priority: P1)

As a maintainer, I can read a green CI run as evidence about the current
Amaru bootstrap producer, without a retired experiment reporting a
successful verdict for a command that no longer exists.

**Why this priority**: The current Phase-0 job deterministically turns an
unrecognized subcommand into the historical format-mismatch verdict and
then succeeds. A false signal makes the whole check board less trustworthy.

**Independent Test**: On the completed branch, enumerate the runnable apps,
flake checks, CI jobs, Just recipes, active documentation, and test helpers.
No executable Phase-0 smoke surface remains; the full flake, the
CLI-mock-honesty negative control, and the live producer verifier all pass.

**Acceptance Scenarios**:

1. **Given** the current repository automation, **when** CI is enumerated,
   **then** there is no Phase-0 smoke verdict job that can report the removed
   conversion command as a valid result.
2. **Given** the current command and check surfaces, **when** a maintainer
   enumerates them, **then** no smoke-test app, recipe, script, check, or
   dedicated test helper remains.
3. **Given** a reviewer wants to understand why the signal was retired,
   **when** they browse the project history, **then** they can find the
   original finding, date, verdict, resulting pivot, and a link to the
   immutable Phase-0 specification.
4. **Given** the retirement changes, **when** the retained verification runs,
   **then** the current producer path and the removed-command negative control
   remain green.

### Edge Cases

- Historical specifications and the constitution continue to name the old
  experiment because they describe what was true at the time; they are not
  active command documentation.
- Historical narrative may show `convert-ledger-state` examples without
  advertising the command as a current repository capability.
- Removing the script without removing its exported flake app would break
  flake evaluation, even if the CI job itself were gone.
- Removing generated output without ignoring its parent directory would allow
  the same artifact tree to be committed again.
- Current producer checks use the Phase-0 fixture as an input. Retirement must
  not delete or rewrite that fixture.

## Requirements

### Functional Requirements

- **FR-001**: The repository MUST remove the dedicated Phase-0 smoke CI job,
  runnable command, recipes, check registrations, script, tests, and test-only
  helpers as one complete retirement.
- **FR-002**: The repository MUST remove the tracked output tree produced by
  the retired smoke run and MUST ignore future generated `tmp/` output.
- **FR-003**: The project history MUST record the Phase-0 finding, its date,
  the `FAIL: format mismatch` verdict, and the pivot it caused, with a link to
  the immutable primary record.
- **FR-004**: Current operator, developer, agent, and API documentation MUST
  stop advertising the retired smoke capability.
- **FR-005**: Historical specifications, the constitution, and the existing
  historical account of what Amaru needed MUST remain unchanged.
- **FR-006**: The real-binary negative control MUST continue to prove that the
  pinned Amaru rejects `convert-ledger-state`.
- **FR-007**: The current producer path MUST remain covered by its synthesized
  bootstrap checks, run-from-bootstrap check, short-epoch golden checks, and
  live cardano-node verifier.
- **FR-008**: The pull request MUST explain the observed conversion exit,
  emitted verdict, successful CI job, retirement decision, and retained
  coverage without relying on private runtime files.
- **FR-009**: Changes to `nix/checks.nix` MUST be localized to the retired
  smoke definitions and registrations so active sibling work is not
  restructured or overwritten.

## Success Criteria

### Measurable Outcomes

- **SC-001**: The repository exposes zero runnable apps, recipes, CI jobs, or
  flake checks named for the retired smoke test.
- **SC-002**: Zero smoke-only scripts, tests, helpers, or tracked generated
  output files remain.
- **SC-003**: One navigable history page records the original verdict and
  points to the unchanged Phase-0 specification.
- **SC-004**: The full flake validation completes with exit code 0 after
  retirement.
- **SC-005**: The CLI-mock-honesty check completes with exit code 0 and still
  reports the removed command as rejected.
- **SC-006**: The live cardano-node 10.7.1 producer verifier completes with
  exit code 0.
- **SC-007**: Every changed active-documentation reference describes current
  producer verification rather than the retired experiment.

## Assumptions

- Phase 0 legitimately concluded `FAIL: format mismatch`; this ticket removes
  the later false-green rerun, not the historical conclusion.
- Substituting a current Amaru command would ask a different question and is
  therefore not a valid repair.
- Generated `site/` output is refreshed by the documentation deployment and
  is not edited directly.
- Current producer checks that consume the Phase-0 fixture remain in scope and
  unchanged apart from removal of dedicated smoke registrations.
