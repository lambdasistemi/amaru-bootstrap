# Feature Specification: Run Amaru Against the Produced Bundle in Live Test

**Feature Branch**: `005-amaru-run-live-test`
**Created**: 2026-05-02
**Status**: Draft
**Input**: GitHub issue [#34](https://github.com/lambdasistemi/amaru-bootstrap/issues/34):
the bundle produced by `bootstrap-producer.sh` looks well-formed on
disk but `amaru run` against it crashes within ~60s with `Invalid VRF
proof: VerificationFailed` and `Consensus died, this should not
happen!`. The consumer boundary is currently untested upstream —
`tests/test-bootstrap-producer-live.bats` asserts only the bundle's
*shape on disk*, never that an Amaru process can actually consume it.

Downstream failing repro:
[cardano-node-antithesis#116](https://github.com/cardano-foundation/cardano-node-antithesis/pull/116).
Amaru fork pinned in the flake at the time of the failure:
[`feat/runtime-testnet-parameters` @ b69fa13e](https://github.com/lambdasistemi/amaru/commit/b69fa13e720aea6453c9c2838114600806ad1b1d).

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Catch consumer-boundary regressions in CI (Priority: P1)

An operator or maintainer of `bootstrap-producer.sh` runs the upstream
live-test (locally or in CI) and gets a clear pass/fail signal that an
emitted bundle is *actually consumable* by `amaru run`, not just
well-shaped on disk.

**Why this priority**: This is the failure described in issue #34.
Today upstream tests pass on bundles that crash Amaru within seconds
when plugged into a real testnet; downstream integrators are the first
place we learn the bundle is broken. Closing the consumer-side test
gap is the whole point of the ticket.

**Independent Test**: Run the extended live-test against the producer
image built from issue #34's failing SHA (`pr-32-ad64e7…` per the
issue body). The extended test must fail with a clearly attributable
VRF / `Consensus died` / `HeaderValidationError` diagnostic. Re-run
against a fixed producer; the test must pass.

**Acceptance Scenarios**:

1. **Given** a producer image whose emitted bundle causes `amaru run`
   to crash within seconds, **When** the extended live-test runs,
   **Then** it fails with the offending Amaru log line(s) surfaced in
   test output (VRF failure, `Consensus died`, or
   `HeaderValidationError`).
2. **Given** a producer image whose emitted bundle is consumable,
   **When** the extended live-test runs, **Then** Amaru is observed
   running for a configurable hold-open window without any of the
   above error classes being emitted, and the test passes.
3. **Given** the live cardano-node container that produced the
   bundle, **When** the extended live-test runs `amaru run` against
   it, **Then** Amaru peers with that node (not a synthetic mock) so
   the VRF/header verification path actually exercises real consensus
   material.

---

### User Story 2 - Make the failure mode obvious from test output (Priority: P2)

A maintainer reading a failed CI log can tell *which* class of
consumer error fired (VRF, rollback inconsistency, peer connection,
generic crash) without re-running locally.

**Why this priority**: Issue #34's root cause is ambiguous between
"snapshot doesn't preserve VRF keys" and "Amaru's verifier disagrees
with cardano-node 10.7.1". A test that just says "Amaru exited"
forces manual log spelunking on every failure. Routing the relevant
lines into test output is cheap and dramatically reduces triage time.

**Independent Test**: Inject a mutated bundle (e.g., corrupt one VRF
key) and run the extended live-test. Output must name the failure
class and quote the offending log line.

**Acceptance Scenarios**:

1. **Given** a bundle that triggers `Invalid VRF proof`, **When** the
   test fails, **Then** the failure message identifies "VRF" as the
   class and prints at least one matching log line.
2. **Given** a bundle that triggers `ledger inconsistency:
   contains_point was true but rollback failed`, **When** the test
   fails, **Then** the failure message identifies the rollback class
   and prints the surrounding context.
3. **Given** Amaru exits cleanly with no error class match
   (unexpected clean exit before the hold window), **When** the test
   fails, **Then** the failure message says so explicitly rather than
   reporting a vague timeout.

---

### User Story 3 - Run inside the existing live-test harness (Priority: P3)

The extended check reuses the live cardano-node 10.7.1 container, the
synthesized ChainDB, and the producer container that the existing
`test-bootstrap-producer-live.bats` already brings up — no parallel
testnet is stood up.

**Why this priority**: Avoids doubling resource cost and prevents
divergence between the "shape" test and the "consume" test. A second
scaffolding would also drift in genesis / network-magic / config and
mask the very class of bug we are trying to catch.

**Independent Test**: Inspect the test invocation; it must reuse
`make_live_node_inputs` / `synthesize_live_chain_db` / the
`$NODE_CONTAINER` already brought up by the existing test, and the
amaru-run step must connect to that container's exposed port.

**Acceptance Scenarios**:

1. **Given** the existing live test passes, **When** the extended
   check is added, **Then** the cardano-node container, ChainDB, and
   producer invocation are not duplicated — only an additional
   Amaru-consume step is appended (or factored into a shared setup).
2. **Given** the test runs, **When** the producer step finishes,
   **Then** the same cardano-node container is still up and reachable
   as Amaru's peer.

---

### Edge Cases

- Amaru may take several seconds to initialise its chain DB before
  emitting any consensus log lines; the hold-open window must start
  *after* the first sign of header processing, not at process start,
  so that a fast-failing crash does not get masked by an early "still
  starting up" allowance.
- The amaru process under test must be the one pinned in this repo's
  flake (the same Rust binary that downstream consumes), not a host-
  installed Amaru.
- Network-magic, genesis hashes, and era-history sidecars in the
  bundle must match what the live cardano-node serves; an apparent
  VRF failure could otherwise be misdiagnosed as bundle corruption
  when it is really a magic mismatch. The test should fail loudly
  when these inputs are inconsistent rather than producing a generic
  VRF error.
- Docker / `db-synthesizer` / image preconditions already cause
  `setup()` to `skip` the existing test; the new assertions must
  inherit those skips and not run partially.
- The hold-open window must be configurable via an environment
  variable so CI can use a longer window than local runs without
  code changes.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The live-test suite MUST, after producing a bundle, run
  `amaru run` against that bundle, peering with the cardano-node
  10.7.1 container that produced the bundle.
- **FR-002**: The amaru binary used MUST be the one pinned in this
  repository's flake (`nix/amaru.nix`, per constitution Principles II
  and III), not a host-installed binary.
- **FR-003**: The test MUST hold Amaru open for a configurable window
  (default ~60 s, overridable via an environment variable analogous
  to the existing `BOOTSTRAP_LIVE_*` family).
- **FR-004**: The test MUST fail if Amaru's logs contain any of:
  `Invalid VRF proof`, `Consensus died`, `HeaderValidationError`, or
  `ledger inconsistency` (the rollback signature from issue #34).
- **FR-005**: The test MUST fail if Amaru exits before the hold-open
  window elapses, regardless of exit code.
- **FR-006**: The test MUST surface the matching Amaru log line(s)
  (and enough surrounding context to triage) in the bats failure
  output.
- **FR-007**: The test MUST reuse the live cardano-node container,
  ChainDB synthesis, and producer invocation already in
  `tests/test-bootstrap-producer-live.bats` rather than standing up a
  parallel testnet.
- **FR-008**: The test MUST inherit existing `setup()` preconditions
  (Docker, db-synthesizer, `BOOTSTRAP_PRODUCER_IMAGE`) — i.e. it must
  `skip` cleanly under the same conditions and not run partially.
- **FR-009**: The teardown path MUST clean up any Amaru container or
  process the new step introduces, on both pass and fail, leaving no
  daemonised state behind.
- **FR-010**: The test MUST NOT fork or vendor Amaru source — it
  consumes the upstream Rust binary as already exposed by
  `nix/amaru.nix` (constitution Principle I).
- **FR-011**: The test MUST be runnable via the existing local
  invocation path (the same way `test-bootstrap-producer-live.bats`
  is run today), so contributors can reproduce the issue #34 failure
  mode on a workstation without bespoke setup.

### Key Entities

- **Bundle under consumer test**: the directory written by
  `bootstrap-producer.sh` to `$TMP_DIR/bundle/testnet_42` — `live/`,
  epoch snapshot subdirectories, `nonces.json`, headers. The same
  bundle the existing test asserts the *shape* of.
- **Live cardano-node peer**: the cardano-node 10.7.1 container the
  existing test brings up; it is the producer of the bundle and also
  Amaru's upstream peer for the consume step. Amaru's VRF / header
  validation runs against headers from this exact node.
- **Pinned Amaru runtime**: the Rust binary exposed by
  `nix/amaru.nix` (currently a fork branch carrying runtime testnet
  parameters; tracked by flake SHA per Principle III). The test
  invokes this binary, not a host-installed copy.
- **Failure-class matchers**: the set of Amaru log substrings the
  test treats as fatal (`Invalid VRF proof`, `Consensus died`,
  `HeaderValidationError`, `ledger inconsistency`).

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Running the extended live-test against the producer
  image named in issue #34 (`pr-32-ad64e7…`) reproduces the failure:
  the test fails, names the failure class, and surfaces the offending
  Amaru log lines — no manual `docker logs` step is required to
  identify the class.
- **SC-002**: Running the extended live-test against a producer image
  whose bundle is known-good results in a green test that observes
  Amaru running for the full configured hold-open window with zero
  matches against any failure-class substring.
- **SC-003**: The extended test adds no new "stand up a parallel
  testnet" cost: the cardano-node container, ChainDB synthesis, and
  producer invocation are reused from the existing live test (one
  cardano-node + one producer + one Amaru per run).
- **SC-004**: When the extended test fails, a maintainer reading
  only the bats output (no separate log fetch) can identify which of
  the four failure classes fired.
- **SC-005**: The extended test runs under the same skip conditions
  as the existing live test — environments without Docker /
  `db-synthesizer` / a producer image still skip cleanly without
  partial runs.

## Assumptions

- The existing live-test scaffolding
  (`tests/test-bootstrap-producer-live.bats` plus
  `tests/lib/bootstrap-helpers`) is the right insertion point. Issue
  #34 explicitly names this file as the place to extend.
- The pinned Amaru binary is exposed via the flake
  (`nix/amaru.nix`) and is invocable from the test environment that
  already has Docker and `db-synthesizer` available — no new
  toolchain is required.
- A ~60 s hold-open window is sufficient to catch the issue #34
  failure modes (the issue reports crashes within seconds, well
  under one minute). Longer windows are available via env-var
  override for CI but are not required by default.
- The extended test stays a docker-reliant bats test, not a Nix
  flake check — same constraint as the existing live test
  ("intentionally NOT a Nix flake check: it needs a Docker daemon").
- Diagnosing *why* a given bundle is rejected (VRF key encoding,
  rollback ledger state, etc.) is out of scope for this spec — that
  is Amaru-side / bootstrap-producer-side investigation tracked
  separately in issue #34's "Asks 2 and 3". This spec only delivers
  the missing detector.
- The extended test peers Amaru with exactly one cardano-node (the
  producer's source node), matching the simplest reproducer in
  issue #34. Multi-peer topologies are out of scope for v1 of this
  test.
