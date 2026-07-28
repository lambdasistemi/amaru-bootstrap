# Feature Specification: Remove the Dead Ledger-State Emitter

**Feature Branch**: `chore/50-remove-ledger-state-emitter`
**Created**: 2026-07-28
**Status**: Draft
**Input**: Issue #50, “Remove the dead ledger-state-emitter executable”

## User Scenarios & Testing

### User Story 1 - Build and Ship Only Live Producer Tools (Priority: P1)

As a maintainer, I build the flake and producer image and observe that the
obsolete `ledger-state-emitter` executable no longer exists in any live source,
build, application, check, test-double, documentation, or image surface.

**Why this priority**: The executable has no caller after the bare-main
migration. Continuing to build and ship it increases maintenance and image
surface while falsely implying that it remains part of the supported pipeline.

**Independent Test**: Build every flake check and the producer image, inspect
the available packages/apps and image contents, audit the live repository
surfaces, and compare the synthesized `testnet_42` bundle's path inventory and
deterministic file subset with the frozen pre-change baseline.

**Acceptance Scenarios**:

1. **Given** the producer uses Amaru's native snapshot creation, **when** a
   maintainer evaluates the flake, **then** no package, app, check, runtime
   path, or image layer exposes the obsolete executable.
2. **Given** the canonical fixture and the same pinned dependencies, **when**
   the producer bundle is built before and after the removal, **then** its 49
   regular-file paths are identical and every file outside the explicitly
   enumerated RocksDB physical-file exclusions is byte-identical.
3. **Given** the repository contains current and historical documentation,
   **when** a maintainer audits exact-name matches, **then** the live-surface
   bucket is empty and every remaining process/history match belongs to an
   enumerated exception.
4. **Given** the canonical CLI test suite, **when** its mocks are installed and
   the mock-honesty check runs, **then** it neither creates nor declares an
   obsolete emitter mock.

### Edge Cases

- Historical specifications, the project history, and the constitution must
  keep describing the executable that genuinely existed at those points in
  time; they are evidence, not live product surface.
- This ticket's own Spec Kit artifacts must name exact paths to remain
  actionable; they form a separate process-document exception.
- Sibling PR #56 added the fail-closed CLI mock-honesty check and changed
  `nix/checks.nix`; the removal must preserve that check unchanged.
- A forced rebuild of the unmodified pre-change bundle measured different NAR
  hashes and apparent sizes. Whole-bundle byte identity is therefore not a
  valid criterion; the exact path inventory and deterministic subset remain
  load-bearing, alongside the semantic bundle checks.

## Requirements

### Functional Requirements

- **FR-001**: The project MUST no longer declare, compile, or expose the
  `ledger-state-emitter` library module or executable.
- **FR-002**: The flake MUST no longer expose the executable as a package, app,
  or check.
- **FR-003**: Producer wrappers, checks, and image construction MUST no longer
  include the executable on their runtime path or in image contents.
- **FR-004**: The canonical CLI bats fixture MUST no longer install an emitter
  mock, and the fail-closed mock-surface declarations MUST remain internally
  consistent.
- **FR-005**: The stale producer-script comment that describes the old
  executable's behavior MUST be removed without changing executable script
  logic.
- **FR-006**: Current-facing maintainer and operator documentation MUST no
  longer advertise the executable.
- **FR-007**: Historical records under `specs/001-*`, `specs/003-*`,
  `specs/004-*`, `specs/051-*`, `docs/history/`, and the constitution MUST
  remain unchanged.
- **FR-008**: The synthesized `testnet_42` bundle MUST match the frozen
  49-path inventory and the frozen content hashes for every file except the 18
  explicitly enumerated RocksDB physical files. The exclusion list MUST name
  each path and MUST be limited to `IDENTITY`, `LOG`, `MANIFEST-*`, `*.sst`,
  and `CURRENT` files.
- **FR-009**: `nix flake check` and the complete explicit Build Gate list MUST
  pass after the removal.
- **FR-010**: The producer image MUST build and contain no executable file
  named `ledger-state-emitter`.
- **FR-011**: The live-surface exact-name audit MUST return zero matches over
  `app/`, `lib/`, `scripts/`, `nix/`, `tests/`, `flake.nix`, `justfile`,
  `.github/`, `amaru-bootstrap.cabal`, `README.md`, `AGENTS.md`, current-facing
  `docs/`, and `skills/`.

## Success Criteria

### Measurable Outcomes

- **SC-001**: The live-surface exact-name audit reports 0 matches.
- **SC-002**: The post-change synthesized bundle matches all 49 frozen paths
  and all 31 frozen deterministic-file hashes. Its measured 202,240-byte sample
  lies between the two unmodified pre-change samples (194,485 and 212,933
  bytes), whose differing NAR hashes prove that whole-bundle size and NAR hash
  are nondeterministic.
- **SC-003**: Flake evaluation exposes 0 packages, apps, or checks named for
  the removed executable.
- **SC-004**: Inspection of the built producer image finds 0 executable paths
  named `ledger-state-emitter`.
- **SC-005**: `nix flake check`, `just build-gate`, and
  `nix build .#checks.x86_64-linux.cli-mock-honesty` each exit 0.

## Assumptions

- The bare-main migration is the supported production pipeline and no external
  consumer relies on the standalone executable.
- PR #56 is merged before implementation, so its CLI mock-honesty check is the
  baseline and its test files are released to this ticket.
- All dependency pins remain unchanged; this is pure dead-code removal.
- Process documents under `specs/050-remove-dead-emitter/` may retain exact
  names because they are the auditable contract for the removal itself.
- The merged sibling record under `specs/051-cli-mock-honesty/` may retain
  exact names because it documents the handoff of emitter removal to this
  ticket.
