# Research: Fatal Amaru Detection

## R-001 - The helper was born orphaned on `main`

**Decision**: Treat commit `2ece5d2` as the introduction point and the
unmerged `87d916c` live consume step as a shape reference only.

**Rationale**: `2ece5d2` is an ancestor of `main` and introduced the
fatal-scan, early-exit, hold-window, and Amaru-run helpers without a caller.
`87d916c` is not an ancestor of `main`; no later migration deleted a caller
from the main line.

**Alternatives considered**:

- Revert a bare-main migration deletion: rejected because no such deletion
  exists.
- Cherry-pick `87d916c`: rejected because it predates current `amaru node run`
  and bundle contracts.

## R-002 - The deterministic check has cleanliness semantics

**Decision**: Keep the existing scanner's “match found” primitive, but expose
one caller-facing cleanliness check that returns nonzero for fatal or unreadable
logs and zero only for readable, clean logs.

**Rationale**: A live caller should be able to use ordinary shell success
semantics: success means clean. It also lets the hard acceptance proof invoke
the exact production-facing check on seeded and clean logs, instead of merely
testing a lower-level grep helper.

**Alternatives considered**:

- Assert only that the scanner returns zero on a match: rejected because that
  does not demonstrate the live check itself fails.
- Duplicate fatal needles in unit and live paths: rejected because the
  vocabulary would drift.

## R-003 - The live consumer runs from the already-loaded image

**Decision**: Start a second container from `BOOTSTRAP_PRODUCER_IMAGE`, override
its entrypoint to the bundled Amaru binary, and run current `amaru node run`
against the produced bundle while sharing the live cardano-node container's
network namespace.

**Rationale**:

- The image already loaded by the live verifier contains the SHA-pinned Amaru
  binary and its runtime dependencies.
- Sharing the node's network namespace gives the consumer a direct
  `127.0.0.1:3001` peer without changing CI, the justfile, or host packages.
- The bundle remains mounted read-write because Amaru's stores rotate logs and
  metadata when opened.

**Alternatives considered**:

- Host-installed Amaru: rejected because the current live CI shell does not
  include it and host state would violate pinning.
- Add Amaru to the CI shell: rejected because `.github/workflows/ci.yml` and
  `justfile` are outside the owned scope.
- A dummy peer: rejected because it cannot exercise header validation.

## R-004 - Observe the hold window continuously

**Decision**: During a positive, configurable hold window, refresh the bounded
container log, run the cleanliness check, and verify container liveness on a
short polling interval. Scan before classifying an early exit so a fatal line
wins over a generic exit diagnostic.

**Rationale**: A fixed sleep followed by one check detects the same failures
eventually but wastes the full window after a fast failure and can misclassify
a fatal exit. Continuous observation fails promptly and preserves the most
specific evidence.

**Alternatives considered**:

- Rely on Docker exit status: rejected because the incident recovers without
  container exit.
- Require only a positive startup marker: rejected because consensus can die
  after startup.

## R-005 - Reuse an existing CI-built flake check

**Decision**: Add deterministic helper tests and the reachability audit to the
existing `bootstrap-producer-bats` derivation in `nix/checks.nix`.

**Rationale**: The required Build Gate already builds that derivation. Creating
a new flake check without changing the justfile and workflow would produce a
check that `nix flake check` sees but the required CI job does not explicitly
build. Reusing the existing check keeps the owned surface localized and the
guard live in CI.

**Alternatives considered**:

- New standalone flake output: rejected unless the owned scope expands to the
  Build Gate lists.
- Convention or documentation only: rejected by the Nix-first invariant.

## R-006 - Reachability is an explicit test-library audit

**Decision**: Audit helper declarations under `tests/lib/` for a non-declaration
call site or an explicit, reviewable exemption. Test the auditor against small
dead and reachable fixtures before running it on the repository helper set.

**Rationale**: The defect is static integration drift: code was copied into a
shared library but never reached from a test entrypoint. A repository audit
fails at the moment such code lands and names the unreachable helper.

**Alternatives considered**:

- Guard only `scan_amaru_log_for_fatal`: rejected because it would fix the
  symptom but not the recurrence class.
- Treat any second textual occurrence as a call: rejected because comments and
  declarations would make the audit vacuous.
- Full Bash semantic call-graph analysis: rejected as disproportionate for the
  repository's simple test-helper conventions.

## R-007 - Antithesis scoring belongs downstream

**Decision**: Keep the scored property out of this PR and link
`cardano-foundation/cardano-node-antithesis#193`.

**Rationale**: The deployed `cardano_amaru` compose and property harness live
in that repository. More importantly, its tracer-sidecar currently tails
cardano-tracer JSON and does not ingest Amaru container stdout, so ingestion
must precede scoring.

**Alternatives considered**:

- Add an assertion in this repository: rejected because no executable
  Antithesis property surface exists here.
- Make this PR wait for the downstream child: rejected by epic-owner ruling
  A-003; the local detector is urgent and independently valuable.

