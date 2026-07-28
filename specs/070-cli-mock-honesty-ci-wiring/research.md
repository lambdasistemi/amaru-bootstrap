# Research: Execute CLI Mock Honesty in the Build Gate

## Decision 1: Extend both existing explicit request lists

**Decision**: Add the already registered
`checks.x86_64-linux.cli-mock-honesty` attribute to the `Build Gate` command in
`.github/workflows/ci.yml` and the matching `build-gate` recipe in `justfile`.

**Rationale**: The repository intentionally names the checks that warm the
shared Nix store. The parent ruling authorizes the smallest change that makes
the existing invariant reachable without redesigning that mechanism.

**Alternatives considered**:

- Replace both lists with `nix flake check`: rejected as an unauthorized gate
  redesign with different evaluation and logging behavior.
- Depend on another requested check to reach this output transitively:
  rejected because reachability would be accidental and could disappear.
- Accept standalone `nix build` evidence: rejected because it does not prove
  either user-facing gate executes the check.

## Decision 2: Prove exact output reachability with a controlled instrument

**Decision**: Evaluate the CLI mock honesty output path, build the exact named
request set with `--print-out-paths`, recursively resolve those outputs with
`nix path-info -r`, and require an exact full-line match for the evaluated
output.

**Rationale**: A recursive closure proves that the command Nix receives can
reach the check output. Exact matching prevents similarly named store paths
from producing a false positive.

**Alternatives considered**:

- Grep workflow text only: retained as a structural assertion, but insufficient
  as execution reachability evidence.
- Search all `/nix/store`: rejected because a warm shared store says nothing
  about the requested derivation set.
- Search derivation names loosely: rejected because substring matches are not
  identity.

**Instrument control**: Before trusting the baseline absence, the same
`nix path-info -r` plus exact-match probe was run against the standalone
output. It found
`/nix/store/iplh6mfib0bj74m6xjpk0szarm99a828-cli-mock-honesty`.
The current explicit Build Gate closure did not. Raw outputs are under
`/tmp/epic-55/amaru-bootstrap-70/logs/`.

## Decision 3: Use a temporary rejected accepted-command as the negative control

**Decision**: Temporarily add the already known rejected
`convert-ledger-state` path to `CLI_MOCK_ACCEPTED_AMARU`, rebuild the standalone
CLI mock honesty check, require a nonzero exit naming that rejection, and
restore the file byte-for-byte before any implementation or GREEN capture.

**Rationale**: This drives the exact declared-versus-real failure the check
exists to detect. It tests the invariant rather than merely causing an
unrelated syntax error.

**Alternatives considered**:

- Break shell syntax: rejected because that proves only that Bash rejects
  malformed input.
- Remove a guard call: rejected because it exercises helper coverage rather
  than the CLI drift acceptance criterion.
- Commit a regression fixture: rejected because issue #70 explicitly forbids
  mock and test changes; the required mutation is evidence-only.

## Decision 4: Keep RED verification outside the committed repository

**Decision**: The driver writes a small assertion script under its runtime
handoff directory before implementation. It checks that both explicit files
name the target and that the exact requested closure reaches the evaluated
output. The script must fail on the baseline and pass after the two-line
wiring change.

**Rationale**: The repository has no separate test harness for these explicit
lists, and a permanent test or parser would exceed the authorized scope. A
runtime assertion preserves RED-GREEN evidence without shipping a second gate
design.

**Alternatives considered**:

- Add a repository test for list reconciliation: rejected as scope expansion.
- Treat the temporary mock drift alone as RED: rejected because that proves
  the check can fail, not that the entry points currently fail to reach it.

## Decision 5: Preserve the full live boundary and hosted proof

**Decision**: Run `just build-gate` for the local entry point, then `./gate.sh`
for all flake checks plus the existing Docker live verifier. After push, wait
for `Build Gate` and `Live Bootstrap Producer`, and retain the hosted Build
Gate log line containing the full CLI mock honesty target.

**Rationale**: The ticket changes CI orchestration. Local Nix success cannot
substitute for the hosted command, and the repository constitution requires
the real node/producer/consumer boundary before handoff.

**Alternatives considered**:

- Run only the focused check: rejected as incomplete repository verification.
- Infer hosted success from local success: rejected because runner wiring is
  the feature under test.

## Scope and dependency finding

Pull request #69 currently touches `gate.sh` and its issue-68 Spec Kit
artifacts; its eventual implementation owns dependency-pin surfaces. It has no
overlap with `.github/workflows/ci.yml` or `justfile`. No merge ordering is
required, and this ticket does not touch its lock or pin.
