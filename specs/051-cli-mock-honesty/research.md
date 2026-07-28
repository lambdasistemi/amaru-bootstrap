# Research: CLI Mock Honesty

## Decision 1: Probe complete command paths

**Decision**: Validate a declared mocked command path by invoking the real
flake-built binary with that complete path followed by `--help`.

**Rationale**: Amaru keeps accepted compatibility commands such as `run`,
`create-snapshots`, `bootstrap`, and `dev` hidden from its top-level command
list. Scraping only the visible list would therefore misclassify accepted
commands as nonexistent.

**Alternatives considered**:

- Parse top-level help: rejected because it omits accepted compatibility
  commands.
- Compare full help text: rejected because wording and formatting are not
  the mock contract.

## Decision 2: Use command-specific evidence for header-extractor

**Decision**: Treat a `header-extractor` path as accepted only when its help
output contains the command-specific `Usage:` line and does not contain an
invalid-argument diagnostic.

**Rationale**: The executable's wrapper maps both successful help and parser
failure to exit code 7, so exit status alone cannot classify its surface.

**Alternatives considered**:

- Exit-code-only probing: rejected because valid and invalid paths have the
  same exit status.

## Decision 3: Fail closed through one shared mock contract

**Decision**: Subcommand-bearing mocks that can report success share one
declared accepted surface and reject everything else before running their
response implementation. The Nix check validates every declared accepted
path against the real binary.

**Rationale**: A separate prose manifest could drift independently from the
mock. Making the declared surface the mock's runtime guard means an invalid
addition cannot become successful without also entering the contract that
the real-binary check verifies.

**Alternatives considered**:

- A prose-only audit list: rejected because it cannot prevent recurrence.
- Replace mocks with real binaries: rejected by the issue's hermetic-test
  non-goal.

## Audit baseline

| Test source | Mock | Successful command surface | Finding |
|---|---|---|---|
| `test-bootstrap-producer-canonical-cli.bats` | `header-extractor` | `tip-info`, `list-blocks`, `get-header`, `prev-epoch-tail` | `prev-epoch-tail` is rejected by the real binary and must be removed |
| `test-bootstrap-producer-canonical-cli.bats` | `amaru` | `snapshot create`, `node bootstrap` | Both canonical paths are accepted |
| `test-bootstrap-producer-history.bats` | `header-extractor` | `tip-info`, `list-blocks` | Both paths are accepted |
| `test-bootstrap-producer-history.bats` | `amaru` | `snapshot create`, `node bootstrap` | Both paths are accepted |
| `test-bootstrap-producer-sparse-boundaries.bats` | `header-extractor` | `tip-info`, `list-blocks` | Both paths are accepted |
| `test-bootstrap-producer-sparse-boundaries.bats` | `amaru` | `snapshot create`, `node bootstrap` | Both paths are accepted |
| `test-amaru-relay-bootstrap.bats` | `amaru` | `run` | Hidden from top-level help but accepted by the real binary |
| `test-relay-entrypoint.bats` | `amaru` | `node run` | Accepted by the real binary |
| `test-tool-error.bats` | `amaru` | Any arguments in the default passing shim | It can report success for rejected `convert-ledger-state`; fail closed |
| `test-tool-error.bats` | `db-synthesizer`, `db-analyser` | Option-only interfaces | No subcommand surface |
| `test-bootstrap-producer-canonical-cli.bats` | `ledger-state-emitter` | Option-only interface | Record only; sibling #50 owns removal |
| `test-amaru-relay-bootstrap.bats` | `bootstrap-producer` | Positional interface | No subcommand surface |

Mocks that always exit nonzero accept no command and do not create the
false-positive class in issue #51.
