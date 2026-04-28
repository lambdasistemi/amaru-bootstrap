# Feature Specification: Snapshot Emitter

**Feature Branch**: `002-snapshot-emitter`
**Created**: 2026-04-27
**Status**: Draft
**Input**: User description: "Phase 1: standalone Haskell tool that converts db-analyser directory snapshots into the single-CBOR-file format amaru convert-ledger-state consumes; closes Phase 0 format mismatch using ouroboros-consensus-cardano as a Cabal library (no fork)"

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Operator closes the format gap (Priority: P1)

An operator running the existing Phase 0 smoke test got the verdict `FAIL: format mismatch`: the upstream chain analyser writes its ledger snapshot in a directory layout, but Amaru's converter only accepts a single file. The operator now runs one additional command, `snapshot-emitter`, that takes the directory the analyser produced and writes the single file Amaru wants. The operator inserts that one command into the existing pipeline (between the dump step and the convert step) and re-runs the smoke test, expecting the verdict to flip to `PASS`.

**Why this priority**: This is the entire purpose of Phase 1. Without this command, every downstream goal (full bootstrap orchestrator, docker image, integration with the consumer testnet) is blocked behind an unbridged format gap. Closing the gap with a tiny standalone tool — and ratifying the no-fork promise made in the project's constitution — is the highest-leverage deliverable in the project right now.

**Independent Test**: An operator with the project checked out runs the existing Phase 0 smoke test against the existing vendored fixture, with the new command inserted into the pipeline. The last line of stdout is `PASS`. No other functionality of the project needs to exist for this story to be testable.

**Acceptance Scenarios**:

1. **Given** the existing Phase 0 smoke test pipeline and the vendored testnet bundle, **When** the operator inserts the snapshot-emitter step between the dump step and the convert step and re-runs the smoke test end-to-end, **Then** the final stdout line is `PASS` and Amaru's converter writes its expected output to disk without error.
2. **Given** a single directory snapshot produced by the upstream analyser, **When** the operator runs the snapshot-emitter against that directory and a target output path, **Then** a single file appears at the target path and Amaru's converter accepts that file as input on a subsequent invocation.
3. **Given** an input directory missing one of the files Amaru's expected snapshot encoding requires, **When** the operator runs the snapshot-emitter, **Then** the tool exits with a non-zero status and an error message that names the missing file, without writing a partial output file.

---

### Edge Cases

- **Output target already exists**: an operator passes a path that already contains a file. The snapshot-emitter must either refuse with a clear error (default) or overwrite atomically only if the operator opts in; partial writes that leave the target in a half-converted state are not acceptable.
- **Input directory is structurally invalid**: a path that is not a directory, an empty directory, or a directory containing the wrong files. The tool must surface the specific structural problem in its error output, not a generic "decode failed".
- **Input snapshot belongs to an era the configured codec does not understand**: the tool must surface that mismatch as a discrete error class — not silently produce a malformed file.
- **Output directory does not exist**: the tool must either create parent directories or refuse with a clear message; either choice must be deterministic, not platform-dependent.
- **Source upstream library evolves the directory layout**: a future upstream change adds or renames a file inside the directory snapshot. The tool must not silently produce wrong output if the layout it sees does not match the layout it was built against.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The snapshot-emitter MUST accept exactly three positional arguments: the path to a directory snapshot (as produced by the upstream chain analyser's snapshot-storing mode), the path to the node configuration document the snapshot was produced against (so the converter can select the matching codec), and the path of the single output file to write.
- **FR-002**: The snapshot-emitter MUST read the directory snapshot's component files in their entirety before writing any byte to the output path.
- **FR-003**: The snapshot-emitter MUST produce an output file that Amaru's existing snapshot-conversion command accepts as input without modification to Amaru.
- **FR-004**: The snapshot-emitter MUST exit with status `0` on success and a documented non-zero status (one of: input-not-found, input-structurally-invalid, decode-error, output-collision, output-write-error) on every failure path.
- **FR-005**: The snapshot-emitter MUST NOT leave a partially written file at the output path on any failure path. Either the file is complete and conformant, or it does not exist.
- **FR-006**: The snapshot-emitter MUST be runnable as a single command from the project root, requiring no manual orchestration of intermediate steps.
- **FR-007**: The snapshot-emitter MUST NOT depend, transitively or directly, on any patched fork of an IOG-maintained source repository - only on stock upstream releases consumed as libraries.
- **FR-008**: When the input directory is missing one or more required files, the snapshot-emitter MUST name the specific missing file(s) in its error output and exit non-zero before attempting any decode.
- **FR-009**: The snapshot-emitter MUST be composable into the existing Phase 0 smoke-test pipeline by inserting one step between the analyser-dump step and the Amaru-convert step. No other change to the pipeline orchestrator is required for the smoke test's verdict to flip from `FAIL: format mismatch` to `PASS`.
- **FR-010**: The snapshot-emitter MUST surface decode errors verbatim from the underlying library; the tool's own error wrapper MUST NOT obscure the originating error message a future operator would search for.

### Key Entities *(include if feature involves data)*

- **Directory snapshot**: a directory on disk produced by the upstream chain analyser's snapshot-storing mode. Contains a fixed set of component files representing one ledger state at one slot. Provided by the operator; not produced by this feature.
- **File snapshot**: a single file on disk that Amaru's snapshot-conversion command accepts. Encoded in the on-disk format Amaru's existing implementation reads. The deliverable artefact of every successful run.
- **Verdict pivot**: a property of the existing Phase 0 smoke test, not a data entity proper. The smoke-test verdict for the vendored fixture moves from `FAIL: format mismatch` (Phase 0 baseline) to `PASS` after this feature is composed into the pipeline.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: An operator can convert a directory snapshot to a file snapshot by running one command with two arguments. No environment variables, no flags, no follow-up commands required.
- **SC-002**: When this feature is composed into the existing Phase 0 smoke test, the verdict for the vendored testnet fixture is `PASS`. The smoke test's wall-clock budget (under five minutes on a developer workstation, per Phase 0 SC-005) absorbs the additional step without breaking the budget.
- **SC-003**: A successful conversion produces a single output file; a failed conversion leaves the output path either unchanged from before invocation, or absent if it was absent before invocation. Two operators inspecting the filesystem after a failed run cannot tell whether the run partially completed.
- **SC-004**: Every failure path emits an error message that names which kind of failure occurred (one of the documented classes in FR-004) AND identifies the specific file or component that caused it, without referencing source-code line numbers, internal types, or library implementation paths.
- **SC-005**: Two consecutive runs of the snapshot-emitter on the same directory snapshot produce byte-identical output files. The conversion is deterministic; no embedded timestamps, no random IDs, no path-dependent encoding.

## Assumptions

- The directory snapshot the operator supplies was produced by the same upstream chain analyser version (or one ABI-compatible with it) that the project pins at the time of conversion. Cross-version compatibility is out of scope; if an operator uses an incompatible analyser version they will get a decode error, which is acceptable.
- Amaru's snapshot-conversion command is treated as a fixed downstream consumer. This feature does not modify or extend Amaru.
- The single-file format Amaru consumes is stable enough that an output produced today will still be accepted by Amaru after a typical upstream Amaru patch release. Major Amaru version bumps may break compatibility and would require a Phase 2 ticket.
- The operator's environment includes the project's standard Nix-built binaries on the path (the project's existing flake-driven workflow); the snapshot-emitter inherits whatever runtime the project's flake provides.
- The directory snapshot is small enough to fit comfortably in operator-workstation memory. The vendored fixture's snapshot is well under 50 MiB; future deployments handling larger snapshots may need a streaming variant - out of scope here.
- An invocation of the snapshot-emitter handles exactly one snapshot. Batching, parallelism, and multi-snapshot pipelines are out of scope.
- Header extraction and nonces composition (the other inputs Amaru's bootstrap eventually needs) are tracked by separate downstream tickets and do not depend on this feature's design.
