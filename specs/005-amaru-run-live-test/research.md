# Research: Run Amaru Against the Produced Bundle in Live Test

**Phase 0** for [spec.md](./spec.md). All decisions consolidated below;
no NEEDS CLARIFICATION remains.

## R-1: How to launch amaru against the live cardano-node container

**Decision**: Publish the node container's N2N port to a random host
port (`docker run -p 127.0.0.1::3001 …`), read the assigned host port
back via `docker port "$NODE_CONTAINER" 3001/tcp`, and invoke the
flake-pinned `amaru run` on the host with
`--peer-address 127.0.0.1:<published-port>`.

**Rationale**:

- amaru is already exposed as a host-runnable binary via `nix/amaru.nix`
  and is used identically by the existing `amaru-run-bootstrap` flake
  check at `nix/checks.nix:418`. Reusing that invocation shape (just
  swapping the dummy `127.0.0.1:9` peer for a real published port) is
  the smallest possible delta.
- Publishing a random host port (`127.0.0.1::3001`) avoids collisions
  on shared / CI hosts and binds to loopback so the live test cannot
  inadvertently expose the node container to the network.
- cardano-node 10.7.1's default N2N port is `3001` and the existing
  fixture's `config.json` does not override `--port`, so `3001/tcp` is
  the right port to publish (no extra `--port` flag needed).

**Alternatives considered**:

- *Run amaru in a sibling docker container on a shared docker network*.
  Rejected: needs a new amaru docker image (or docker-mounted Nix
  closure) for no functional gain; and amaru is already cleanly
  invocable from the host today.
- *Use the node container's existing UDS at `$TMP_DIR/ipc/node.socket`
  as the peer address*. Rejected: amaru's `--peer-address` is N2N (TCP),
  not the local socket protocol the UDS speaks. Different protocol;
  not what we want to verify.
- *Publish to a hard-coded host port (e.g. 30001)*. Rejected: collides
  on parallel test runs and on CI machines with arbitrary state.

## R-2: Where to attach the new assertions

**Decision**: Extend the *existing* `@test "producer reads a
cardano-node 10.7.1 ChainDB while the node has it open"` in
`tests/test-bootstrap-producer-live.bats`. Add the amaru-consume block
*after* the existing on-disk shape assertions and *before* teardown,
inside the same `@test`.

**Rationale**:

- bats runs `setup()` per `@test`. A new sibling `@test` would bring up
  a second cardano-node + a second ChainDB synthesis, doubling
  resource cost — exactly what FR-007 / US-3 forbid.
- The existing on-disk shape assertions (lines 152–159) are cheap and
  retained as a precondition: if they fail there is no point trying to
  consume the bundle. Sequencing inside one `@test` is simplest and
  matches the issue's "extend the live-test scaffolding" wording.
- Failure-class diagnostics (FR-004 / FR-006) are emitted before the
  final assertion fires so even when the test fails, the bats output
  carries the offending log lines.

**Alternatives considered**:

- *New file `tests/test-bootstrap-producer-amaru-run.bats` with
  duplicated `setup()`*. Rejected: doubles cardano-node startup cost,
  doubles ChainDB synthesis (~minutes), and risks drift between the
  two harnesses (different network-magic / config / image override is
  exactly the bug we are trying to detect).
- *Sibling `@test` in the same file relying on bats `setup_file()`*.
  Rejected: would need substantial restructuring of the existing
  `setup()` (which references `$BATS_TEST_NUMBER`) and gives no gain
  over a single combined `@test`.

## R-3: Fatal log substring matchers

**Decision**: Treat the following as fatal (all four classes from
issue #34's failure log; matched against amaru's stderr+stdout
combined). On any match, fail the test with a class label and 5 lines
of surrounding context:

| Class label    | Substring matched               |
|----------------|---------------------------------|
| `vrf`          | `Invalid VRF proof`             |
| `consensus`    | `Consensus died`                |
| `header`       | `HeaderValidationError`         |
| `rollback`     | `ledger inconsistency`          |

**Rationale**:

- These are the literal strings issue #34 enumerates as the observed
  failure modes; matching them directly is the most defensible
  behaviour-contract for a "did the bundle work?" test.
- Substring (not regex) keeps the matcher trivially shellcheck-clean
  and resistant to amaru's structured-trace formatting changes.
- Reporting context (5 lines around the match) lets the maintainer
  triage from CI without a separate `docker logs` step (SC-004).

**Alternatives considered**:

- *Whitelist-based ("must contain `build_ledger`")*. Rejected: amaru's
  ledger startup is *not* the failure window for issue #34 — the
  existing `amaru-run-bootstrap` check already proves startup. The
  failure window is the live header-replay phase, which has no single
  "I am healthy" success line we can rely on. A blacklist-with-hold-
  open is the right shape.
- *Exit-code-only signal*. Rejected: amaru can crash with rc!=0 for
  many reasons; FR-004 specifically demands surfacing the failure
  class, which exit codes alone do not provide.

## R-4: Hold-open semantics and configurability

**Decision**: amaru is launched in the background; the test sleeps
`BOOTSTRAP_LIVE_AMARU_HOLD_SECONDS` (default `60`); then it (a) checks
the amaru process is still alive, (b) scans the captured log for
fatal substrings, (c) sends `SIGTERM`+wait for amaru to terminate
cleanly. Failure of (a) → "exited early" failure (FR-005); failure of
(b) → class-labelled failure (FR-004); both succeed → test continues
to teardown and passes.

**Rationale**:

- 60 s default exceeds the issue #34 reproducer's "crashes within
  ~60s" timing comfortably, while keeping the local feedback loop
  short.
- Env-var override (`BOOTSTRAP_LIVE_AMARU_HOLD_SECONDS`) follows the
  established `BOOTSTRAP_LIVE_*` pattern (`BOOTSTRAP_LIVE_TMPDIR`,
  `BOOTSTRAP_LIVE_SLOTS`).
- The failure-mode "amaru exited cleanly before the hold window"
  (US-2 acceptance scenario 3) is reported as its own class to avoid
  ambiguity vs. a vague timeout.

**Alternatives considered**:

- *Wait for a positive "synced" signal in amaru logs*. Rejected: too
  brittle and not why this test exists; we are detecting the absence
  of the four failure classes, not the presence of a healthy steady
  state.
- *Run amaru with `timeout 60s amaru run`*. Rejected: works but loses
  the ability to send SIGTERM cleanly + harvest logs in a single
  controlled flow, and conflates "exited early" and "still healthy at
  60s" into the same exit code.

## R-5: Skip predicates

**Decision**: Add `command -v amaru >/dev/null 2>&1 || skip "amaru
unavailable"` to `setup()` (or a `setup_file` equivalent). Inherit all
existing skip predicates unchanged.

**Rationale**:

- The existing `live-bootstrap-producer` justfile recipe brings
  `bats`, `docker-client`, `db-synthesizer`, etc. into the shell via
  `nix shell`. Extending it to also bring `amaru` (`.#amaru` or
  equivalent flake output) makes the precondition satisfied during
  the canonical local invocation. The skip predicate keeps the bats
  file useful when invoked directly without that wrapper.

**Alternatives considered**:

- *Hard-error if amaru is missing*. Rejected: breaks parity with the
  existing live test's "skip cleanly when prerequisite is absent"
  ergonomic.

## R-6: Cleanup & teardown

**Decision**: Track the amaru background PID and its container-side
log file in test-scoped variables (e.g. `AMARU_PID`,
`AMARU_LOG_FILE`). In `teardown()`, after the existing `docker rm -f`
calls: `kill -TERM "$AMARU_PID" 2>/dev/null || true` then `wait
"$AMARU_PID" 2>/dev/null || true`. Rely on `$TMP_DIR` removal (already
handled by `docker_rm_worktree`) for log cleanup.

**Rationale**:

- amaru runs on the host (not in docker), so `docker rm` does not
  reap it. An explicit kill in teardown prevents stray amaru
  processes after a failed run.
- Same SIGTERM-then-wait shape used by the existing node-monitor
  background loop (lines 67–70 of the current bats file).

## Consolidated open questions

None. All five spec FRs covered by R-1…R-6.
