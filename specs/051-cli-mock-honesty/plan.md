# Implementation Plan: CLI Mock Honesty

**Branch**: `test/51-cli-mock-honesty` | **Date**: 2026-07-28 |
**Spec**: [spec.md](spec.md)  
**Input**: Feature specification from
`/specs/051-cli-mock-honesty/spec.md`

## Summary

Remove the nonexistent `header-extractor prev-epoch-tail` response and
make every success-capable, subcommand-bearing test double pass through a
shared fail-closed command-surface guard. Add a Nix check that probes each
declared accepted path against the corresponding real flake-built binary.
The detailed command audit and nonstandard help behavior are recorded in
[research.md](research.md).

## Technical Context

**Language/Version**: Bash 5 and Bats  
**Primary Dependencies**: Existing flake-built `amaru` and
`header-extractor`; Nix `runCommand`  
**Storage**: None  
**Testing**: Bats regression assertions, a shell command-surface checker,
and `nix flake check`  
**Target Platform**: x86_64 Linux under the repository's Nix flake  
**Project Type**: Test harness and build check  
**Performance Goals**: Preserve fast hermetic bats suites; the honesty
check performs help-only binary probes  
**Constraints**: `tests/` plus minimal localized `nix/checks.nix` wiring;
no production or dependency changes  
**Scale/Scope**: The current in-repo executable test doubles

## Constitution Check

- **No forks**: Pass. The check uses the already SHA-pinned upstream
  binaries without modification.
- **Stock tools**: Pass. No tool behavior is reimplemented; only test
  doubles and their verifier change.
- **Pin by SHA**: Pass. No flake input or lock file changes.
- **Nix-first**: Pass. The honesty contract is a flake check and the final
  proof is `nix flake check`.
- **Smallest provable step**: Pass. One test-only vertical slice removes
  the known false surface and installs the recurrence check.
- **Bundle output contract**: Pass by construction. No producer or bundle
  code changes.

## Design

### Shared declared surface

`tests/lib/cli-mock-surface.bash` owns:

- the accepted command paths for `header-extractor` and `amaru`;
- a query interface used by the real-binary checker; and
- a guard invoked at the start of every success-capable mock of those
  binaries.

The guard classifies only the command path. Arguments after an accepted
path remain under each test double's existing behavior. Unknown paths fail
before a mock can report success.

### Real-binary checker

`tests/check-cli-mock-honesty.sh` reads the same declared surface used by
the runtime guard and probes each path with `--help`.

- Amaru acceptance requires exit 0.
- `header-extractor` acceptance requires its command-specific usage text
  and no invalid-argument diagnostic because its wrapper returns 7 for
  both valid help and parser errors.
- Known invalid paths are regression probes.
- The checker also confirms that every currently audited
  success-capable subcommand mock invokes the shared guard, so adding an
  unguarded mock is visible.

### Nix wiring

Add one localized `cli-mock-honesty` derivation to `nix/checks.nix`. Its
inputs are Bash, the test source, `amaru`, and `header-extractor`; it runs
the checker without changing existing checks.

## Project Structure

```text
specs/051-cli-mock-honesty/
├── checklists/requirements.md
├── plan.md
├── research.md
├── spec.md
└── tasks.md
tests/
├── check-cli-mock-honesty.sh
├── lib/cli-mock-surface.bash
└── existing *.bats mock owners
nix/
└── checks.nix
```

**Structure Decision**: Keep the command contract with test helpers and
the executable comparison with tests. Nix only supplies real binaries and
publishes the result as a flake check.

## Slice Plan

### Slice 1 - Guard and verify mocked CLI surfaces

Add failing regression assertions for the two known false-positive
surfaces, then implement the shared guard, apply it to all audited
subcommand-bearing mocks, add the real-binary checker, and wire the new
flake check. This lands as one bisect-safe commit because the recurrence
check and guarded mocks are one vertical behavior contract.

**Owned files**:

- `tests/lib/cli-mock-surface.bash`
- `tests/check-cli-mock-honesty.sh`
- `tests/test-bootstrap-producer-canonical-cli.bats`
- `tests/test-bootstrap-producer-history.bats`
- `tests/test-bootstrap-producer-sparse-boundaries.bats`
- `tests/test-amaru-relay-bootstrap.bats`
- `tests/test-relay-entrypoint.bats`
- `tests/test-tool-error.bats`
- `nix/checks.nix`

**Focused proof**:

```text
nix build .#checks.x86_64-linux.cli-mock-honesty
nix build .#checks.x86_64-linux.bootstrap-producer-bats
nix build .#checks.x86_64-linux.smoke-test-bats
./gate.sh
```

### Slice 2 - Publish the audit evidence (orchestrator-owned)

After accepting and pushing Slice 1, the ticket orchestrator updates the
human-readable PR body with the full audit findings and fresh verification
evidence, checks the parent inbox, closes the task accounting, and runs the
final gate and commit audit. No driver or navigator edits this metadata
slice.

**Owned artifacts**:

- `specs/051-cli-mock-honesty/tasks.md`
- Pull request #56 body
- `/tmp/epic-55/amaru-bootstrap-51/inbox/`

## Complexity Tracking

No constitutional violation or complexity exception is required.
