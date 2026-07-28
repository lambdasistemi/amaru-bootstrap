# Feature Specification: CLI Mock Honesty

**Feature Branch**: `test/51-cli-mock-honesty`
**Created**: 2026-07-28
**Status**: Ready for planning
**Input**: GitHub issue
[`lambdasistemi/amaru-bootstrap#51`](https://github.com/lambdasistemi/amaru-bootstrap/issues/51)

## User Scenarios & Testing

### User Story 1 - Trust mocked command surfaces (Priority: P1)

As a maintainer, I can run the repository checks and know that a test
double never reports success for a CLI subcommand that its corresponding
flake-built binary rejects.

**Why this priority**: A permissive mock creates false confidence and has
already allowed removed CLI shapes to survive until the Build Gate.

**Independent Test**: Introduce a nonexistent command into an in-scope
mock's accepted surface and run the mock-honesty check. The check must
fail. Restore only real accepted commands and the check must pass.

**Acceptance Scenarios**:

1. **Given** the canonical `header-extractor` mock, **when**
   `prev-epoch-tail` is requested, **then** the mock rejects the command.
2. **Given** an accepted command path declared by an in-scope mock,
   **when** the mock-honesty check probes the corresponding real binary,
   **then** the real binary accepts that command path.
3. **Given** a command path that the real binary rejects, **when** a
   guarded mock receives it, **then** the mock fails before its response
   implementation can report success.
4. **Given** all ticket changes, **when** `nix flake check` runs, **then**
   every flake check succeeds.

### Edge Cases

- Some accepted Amaru compatibility commands are hidden from top-level
  help. Acceptance is determined by probing the complete command path
  with `--help`, not by scraping only the visible command list.
- `header-extractor` maps both successful help and parse failures to exit
  code 7. Its probe must distinguish the command-specific usage text from
  an invalid-argument diagnostic.
- Binaries with option-only or positional-only interfaces have no mocked
  subcommand surface to compare.
- Mocks that always fail do not accept any command path and therefore
  cannot create the false-positive behavior addressed by this feature.
- The `ledger-state-emitter` test double is recorded by the audit but is
  not changed because sibling issue #50 owns its removal.

## Requirements

### Functional Requirements

- **FR-001**: The canonical `header-extractor` mock MUST reject
  `prev-epoch-tail`.
- **FR-002**: Every executable test double under `tests/` MUST be audited
  against the real CLI it represents.
- **FR-003**: Every successful subcommand path accepted by an in-scope
  mock for a flake-built binary MUST also be accepted by the real binary.
- **FR-004**: In-scope subcommand-bearing mocks MUST fail closed for
  command paths outside their declared accepted surface.
- **FR-005**: A Nix flake check MUST validate the declared accepted mock
  surfaces against the flake-built binaries.
- **FR-006**: Existing fast, hermetic return-code tests MUST remain
  mock-based.
- **FR-007**: Audit findings MUST be recorded in the pull request body in
  language understandable without access to private runtime files.
- **FR-008**: Production scripts, application code, dependency pins,
  historical Phase-0 records, and sibling issue #50's
  `ledger-state-emitter` removal MUST remain unchanged.

## Success Criteria

### Measurable Outcomes

- **SC-001**: All successful mocked command paths for flake-built binaries
  are accounted for by one executable honesty contract.
- **SC-002**: The known invalid paths `header-extractor
  prev-epoch-tail` and `amaru convert-ledger-state` are rejected by the
  guarded mock contract.
- **SC-003**: Adding any rejected command path to the accepted mock
  contract makes the mock-honesty check exit nonzero.
- **SC-004**: `nix flake check` completes with exit code 0 after the
  implementation.
- **SC-005**: No file outside `tests/`, the minimal `nix/checks.nix`
  wiring, this feature's `specs/` artifacts, and the temporary
  ticket-local `gate.sh` is changed.

## Assumptions

- Command-path compatibility, rather than byte-for-byte help output, is
  the maintained contract.
- A mock may intentionally reject a real compatibility alias when the
  test is enforcing the canonical spelling; false rejection does not
  create the false-positive failure addressed here.
- Test doubles for third-party programs not built by this flake are
  recorded by the audit but excluded from executable comparison.
