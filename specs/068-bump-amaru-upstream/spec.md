# Feature Specification: Bump Amaru to Upstream Main

**Feature Branch**: `chore/bump-amaru-pin-upstream-main`
**Created**: 2026-07-28
**Status**: Ready for planning
**Input**: GitHub issue
[`lambdasistemi/amaru-bootstrap#68`](https://github.com/lambdasistemi/amaru-bootstrap/issues/68)

## User Scenarios & Testing

### User Story 1 - Consume the current upstream Amaru (Priority: P1)

As a bootstrap-producer maintainer, I can adopt the current stock
`pragma-org/amaru` main revision and know that the repository's declared
command surfaces, producer build, and live node-to-Amaru boundary still
match the real upstream binary.

**Why this priority**: The producer image is a supplier artifact for the
Antithesis testnet. Its consumer cannot validate the next image until the
producer builds against the intended upstream revision without mocks
hiding command drift.

**Independent Test**: Freeze the upstream main revision immediately before
the update, prove the old pin does not equal it, adopt that exact revision,
and then show that the real-binary command-surface check, complete build
gate, and live producer/consumer verifier all exit zero.

**Acceptance Scenarios**:

1. **Given** the repository is pinned to an older Amaru revision, **when**
   execution-time upstream main is frozen, **then** both dependency records
   resolve to that exact stock upstream commit and no fork or moving ref is
   introduced.
2. **Given** upstream changed a command accepted by a test double, **when**
   the honesty check probes the real binary, **then** the stale declaration
   fails and must be reconciled to the real command surface before the gate
   can pass.
3. **Given** the new revision and any evidence-required surface
   reconciliation, **when** the full repository and live-boundary gates run,
   **then** every check succeeds without weakening an assertion.
4. **Given** the upstream consensus repair is not in the selected revision,
   **when** this supplier bump is reported, **then** no result claims that
   the downstream fatal-consensus property is fixed or expected green.

### Edge Cases

- Upstream main can advance between issue filing and execution. The target
  is the SHA observed immediately before the implementation edit, captured
  mechanically with raw output.
- If upstream pull request `pragma-org/amaru#1098` becomes part of the
  selected main revision before implementation, the issue's expected-red
  premise has changed. The ticket stops for an operator ruling instead of
  silently changing that acceptance statement.
- Updating one dependency can accidentally rewrite unrelated lock entries.
  Every non-Amaru lock node must remain byte-for-byte unchanged.
- A real binary can retain a compatibility alias that is absent from
  top-level help. Command-path acceptance is determined by the executable
  honesty contract, not by help-text scraping alone.
- A command-surface failure is positive evidence that the check works.
  Reconciliation must follow the real binary and must not add a permissive
  mock, compatibility fork, or assertion skip.
- A local gate can pass while the hosted runner or Docker seam fails.
  Both named pull-request checks remain required before final review.

## Requirements

### Functional Requirements

- **FR-001**: The execution-time `pragma-org/amaru` main SHA MUST be
  captured from upstream immediately before the pin edit, with the raw
  result retained as evidence.
- **FR-002**: The repository's declared Amaru source and resolved lock
  record MUST both name exactly that captured full commit SHA.
- **FR-003**: The source MUST remain bare `pragma-org/amaru` with no fork,
  patch, branch overlay, moving tag, or vendored upstream code.
- **FR-004**: Every lock entry unrelated to Amaru MUST remain unchanged.
- **FR-005**: The real-binary CLI honesty contract MUST pass for every
  accepted Amaru mock command and MUST remain proven able to fail for a
  rejected command.
- **FR-006**: If the real binary rejects a currently declared mock command,
  only the declared command surface and its tests MAY be reconciled in this
  ticket; broader producer behavior requires an operator-approved scope
  change.
- **FR-007**: The complete repository gate, including the live
  cardano-node-to-Amaru boundary, MUST exit zero on the final branch.
- **FR-008**: Pull-request checks named `Build Gate` and
  `Live Bootstrap Producer` MUST both conclude successfully at the final
  reviewed commit.
- **FR-009**: The pull request MUST state that this ticket does not fix
  Amaru consensus and that the later Antithesis fatal-consensus assertion
  remains expected red when the selected upstream revision excludes
  `pragma-org/amaru#1098`.
- **FR-010**: Compose pins, the consensus-fix payoff in issue #67, upstream
  consensus code, and cardano-node-antithesis issue #195 MUST remain
  unchanged.
- **FR-011**: Acceptance evidence MUST preserve raw combined output, real
  command exit codes, and hashes captured only after the final relevant
  edit in a separate sequential step.

## Success Criteria

### Measurable Outcomes

- **SC-001**: Exactly one stock upstream Amaru commit identity appears in
  both dependency records, and it equals the mechanically captured
  execution-time main SHA.
- **SC-002**: A seeded rejected Amaru command makes the CLI honesty
  instrument exit nonzero, while the unmodified accepted surface exits
  zero against the selected binary.
- **SC-003**: The final complete local gate exits 0 with all flake checks
  and the live producer/consumer observation passing.
- **SC-004**: Both required pull-request checks conclude success on the
  final reviewed commit.
- **SC-005**: The implementation diff contains zero changes outside the
  two dependency records unless a real-binary failure justifies changes
  within the explicitly allowed CLI declaration and test surface.
- **SC-006**: The pull request makes zero claims that the open upstream
  consensus repair has landed or that the expected downstream red result
  is green.

## Assumptions

- At intake, upstream main is
  `e706976205ff4600cb74fcb616a7f632de39c8a9`, and
  `pragma-org/amaru#1098` is open and not merged.
- The implementation pair rechecks both facts immediately before editing;
  the freshly observed state, not the intake snapshot, controls the pin.
- The current `cli-mock-honesty` check is the permanent declared-vs-real
  command-surface invariant and remains in the full flake gate.
- Image publication under the eventual main merge SHA occurs after the
  operator merges; publication itself is outside this no-merge run.
