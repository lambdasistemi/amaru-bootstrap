# Feature Specification: Snapshot Format Smoke Test

**Feature Branch**: `001-snapshot-format-smoke`
**Created**: 2026-04-27
**Status**: Draft
**Input**: User description: "Phase 0 smoke test: verify db-analyser --store-ledger output format matches amaru convert-ledger-state input format, using only stock IOG tools (no fork of ouroboros-consensus)"

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Operator validates the no-fork hypothesis (Priority: P1)

An operator setting up an Amaru node on a custom Cardano testnet runs a single command and learns, in under five minutes, whether the bootstrap pipeline can be built from stock upstream tooling or whether the project must pivot to a different approach. The operator sees one of three clear outcomes - `PASS`, `FAIL: format mismatch`, or `FAIL: tool error` - together with the artefacts produced (so the failure can be inspected without rerunning).

**Why this priority**: This is the entire purpose of Phase 0. Until this hypothesis is settled, no further work in the project is justified. Every subsequent phase (full bootstrap orchestrator, docker image, consumer wiring) sits on this single load-bearing assumption. Settling it cheaply is the highest-leverage deliverable.

**Independent Test**: An operator with the project checked out runs the smoke test against a pre-supplied input bundle and reads the verdict. No other functionality of the project needs to exist for this to deliver value: the verdict alone is the deliverable.

**Acceptance Scenarios**:

1. **Given** a valid pre-generated testnet input bundle (node config, genesis files, bulk credentials for at least one pool) and a working tool environment, **When** the operator invokes the smoke test, **Then** the smoke test produces a chain database covering at least one full epoch, dumps a ledger snapshot at the epoch boundary, feeds the snapshot to Amaru's converter, and reports `PASS` with the path to the converted snapshot artefact.
2. **Given** the same valid input bundle and environment, **When** Amaru's converter rejects the snapshot the upstream tool emitted, **Then** the smoke test reports `FAIL: format mismatch` together with the rejected snapshot file path and Amaru's exact error output.
3. **Given** the same valid input bundle but a synthesis or analysis step fails before reaching the converter, **When** the smoke test detects the failure, **Then** it reports `FAIL: tool error` together with which step failed, the failing tool's exit code, and a path to that tool's full stderr output.

---

### Edge Cases

- **Insufficient synthesis duration**: the operator requests fewer slots than one epoch, so no epoch boundary exists to dump a snapshot at. The smoke test must detect this before invoking the analysis step and report `FAIL: configuration error` with a clear message about the minimum required duration.
- **Stale artefacts from a previous run**: leftover chain database or snapshot files from a prior invocation could mask a real failure or produce misleading PASS. The smoke test must start from a clean output directory each run, or refuse to run if the output directory is non-empty.
- **Network params drift**: the input bundle specifies parameters (e.g. epoch length, security parameter) that are not internally consistent with the genesis files. The smoke test must rely on the configured tools' own validation and surface their error verbatim, not silently proceed.
- **Wall-clock variability of the verdict**: the synthesis step duration is dominated by IO and the requested epoch count. The verdict-completion time bound must reflect the configured input, not be a hard absolute number.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The smoke test MUST accept a pre-supplied input bundle consisting of a node configuration document, the genesis documents it references, and a bulk-credentials document for at least one block-producing pool.
- **FR-002**: The smoke test MUST produce a chain database covering at least one full epoch boundary, derived from the input bundle, using a stock upstream synthesis tool that is consumed without modification.
- **FR-003**: The smoke test MUST dump a ledger-state snapshot at one identified epoch boundary in the produced chain database, using a stock upstream analysis tool that is consumed without modification.
- **FR-004**: The smoke test MUST feed the dumped snapshot to Amaru's snapshot conversion command and observe whether Amaru accepts the snapshot as input.
- **FR-005**: The smoke test MUST emit a single, machine-readable verdict that is one of: `PASS`, `FAIL: format mismatch`, `FAIL: tool error`, or `FAIL: configuration error`.
- **FR-006**: The smoke test MUST, alongside the verdict, retain on disk and report the paths to: the produced chain database, the dumped snapshot file, and the full stderr output of every tool it invoked.
- **FR-007**: The smoke test MUST refuse to mix output with artefacts from prior invocations: it either starts from an empty output directory or fails fast with a clear message.
- **FR-008**: The smoke test MUST be runnable as a single command from the project root, requiring no manual orchestration of intermediate steps by the operator.
- **FR-009**: The smoke test MUST NOT depend, transitively or directly, on any fork of `ouroboros-consensus`, `cardano-node`, or any IOG-maintained repository - only stock upstream releases pinned to exact versions or commit hashes.
- **FR-010**: When the verdict is `FAIL: format mismatch`, the smoke test MUST surface Amaru's complete error output, so the failure mode can be diagnosed without rerunning the tools manually.

### Key Entities *(include if feature involves data)*

- **Input bundle**: a collection of pre-generated documents (node config, genesis files, bulk credentials) that together describe a self-contained custom testnet and the keys needed to forge blocks on it. Provided by the operator; not produced by this feature.
- **Synthesised chain database**: an on-disk Cardano chain database covering a configurable number of epochs, derived from the input bundle.
- **Ledger snapshot**: a single on-disk artefact representing Cardano ledger state at one epoch-boundary slot, dumped from the synthesised chain database.
- **Verdict**: a single-line outcome label plus structured detail (paths, exit codes, error text) emitted at the end of every smoke-test run.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: An operator unfamiliar with the codebase can determine the project's go/no-go answer (no-fork path viable or not) by running one command and reading its final line of output, without consulting source code.
- **SC-002**: A `PASS` verdict provides sufficient evidence to commit to the no-fork architecture for the rest of the project; a `FAIL: format mismatch` verdict provides sufficient evidence to escalate to designing a small standalone snapshot-emitter that depends on consensus libraries (still no fork).
- **SC-003**: Every run of the smoke test, regardless of verdict, leaves on disk all artefacts needed to investigate the outcome - no operator should ever need to rerun the test just to recover a missing log or intermediate file.
- **SC-004**: Two consecutive runs of the smoke test on the same input bundle and the same tool versions produce the same verdict. Non-determinism in synthesis output content is acceptable; non-determinism in the verdict is not.
- **SC-005**: The total wall-clock time for a `PASS` run on the minimum viable input bundle (one epoch, one pool) does not exceed five minutes on a developer workstation.

## Assumptions

- The operator supplies a valid, pre-generated input bundle. The smoke test does not generate testnet configurations, keys, or genesis files; producing those is outside the project's scope.
- The amaru binary used by the smoke test is the same one the project will use in Phase 1 and beyond, sourced from the project's pinned upstream dependency. Version drift between the smoke test and downstream phases is not a concern at this stage.
- The upstream tools (`db-synthesizer`, `db-analyser`) are available as released binaries or build cleanly from a pinned upstream tag; if neither is true at the time of implementation, that constitutes a discovery of additional Phase 0 risk separate from the format hypothesis itself.
- Header extraction, nonces composition, and Amaru's `import-ledger-state` / `import-headers` / `import-nonces` commands are explicitly out of scope for Phase 0. Only the snapshot-format compatibility is on the critical path.
- The operator runs the smoke test on a Linux developer workstation with enough disk space (a few hundred megabytes) and CPU to comfortably synthesise one epoch. Constrained environments (CI runners with tight disk quotas, low-memory containers) are not a Phase 0 concern.
- A single epoch boundary is sufficient to validate the format hypothesis. If Amaru's converter accepts one upstream-emitted snapshot, the project commits to the no-fork path. If multi-epoch behaviour later proves divergent, that surfaces in Phase 1 and is not a Phase 0 failure.
