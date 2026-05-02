# Data Model: Run Amaru Against the Produced Bundle in Live Test

This feature has no persistent data model — it is a test extension.
The model below enumerates the *test-scoped artefacts* the new code
introduces, since they are non-trivial and need disciplined cleanup.

## Test-scoped artefacts

### `BUNDLE_DIR` *(reused, not new)*

- **Path**: `$TMP_DIR/bundle/testnet_42`
- **Source**: written by `bootstrap-producer.sh` during the existing
  test phase.
- **Used by**: amaru `--ledger-dir` and `--chain-dir` arguments
  (`$BUNDLE_DIR/ledger.testnet_42.db` and
  `$BUNDLE_DIR/chain.testnet_42.db` respectively, identical to the
  layout the `amaru-run-bootstrap` flake check at `nix/checks.nix:418`
  consumes).

### `NODE_HOST_PORT` *(new)*

- **Source**: `docker port "$NODE_CONTAINER" 3001/tcp` — the host port
  docker assigned when the node container was started with
  `-p 127.0.0.1::3001`.
- **Used by**: amaru `--peer-address 127.0.0.1:$NODE_HOST_PORT`.
- **Lifetime**: scoped to the docker container; reaped automatically
  by the existing `docker rm -f "$NODE_CONTAINER"` in teardown.

### `AMARU_LOG_FILE` *(new)*

- **Path**: `$TMP_DIR/amaru-run.log`
- **Content**: combined stdout+stderr of the backgrounded
  `amaru run` process.
- **Used by**: failure-class scanner (`grep -F` for the four
  substrings) and bats output on test failure.
- **Lifetime**: removed alongside `$TMP_DIR` by `docker_rm_worktree`.

### `AMARU_PID` *(new)*

- **Source**: `$!` after `amaru run … >"$AMARU_LOG_FILE" 2>&1 &`.
- **Used by**: hold-open liveness check (`kill -0 "$AMARU_PID"`) and
  teardown (`kill -TERM "$AMARU_PID"; wait "$AMARU_PID"`).
- **Lifetime**: explicitly killed in teardown, regardless of pass /
  fail / skip.

### `BOOTSTRAP_LIVE_AMARU_HOLD_SECONDS` *(new env-var input)*

- **Type**: integer, seconds.
- **Default**: `60` (per FR-003).
- **Validation**: must be a positive integer; the test should error
  out (`fail`, not `skip`) on malformed values rather than silently
  using the default.

## Relationships

```text
BUNDLE_DIR ────► amaru run ◄──── NODE_HOST_PORT (publishes :3001 from $NODE_CONTAINER)
                    │
                    ▼
              AMARU_PID ──── AMARU_LOG_FILE
                                  │
                                  ▼
                      failure-class scanner
                                  │
                                  ▼
                            bats output
```

## State transitions (per test invocation)

```text
[setup: skip predicates pass]
  → start NODE_CONTAINER with -p 127.0.0.1::3001
  → wait_for_node_socket
  → run producer (existing on-disk shape assertions)
  → [new] read NODE_HOST_PORT from docker port
  → [new] launch amaru run in background → AMARU_PID
  → [new] sleep BOOTSTRAP_LIVE_AMARU_HOLD_SECONDS
  → [new] liveness check on AMARU_PID
        ├── dead → FAIL "amaru exited early"
        └── alive → continue
  → [new] scan AMARU_LOG_FILE for fatal substrings
        ├── match → FAIL "<class>: <surrounding context>"
        └── clean → PASS
  → [teardown] SIGTERM AMARU_PID; docker rm -f containers; rm $TMP_DIR
```

## Invariants

- **I-1**: `AMARU_PID` is always either `""` or a process the test owns;
  teardown must tolerate either.
- **I-2**: A green run leaves no amaru processes on the host (kill +
  wait in teardown).
- **I-3**: A failed run still surfaces `AMARU_LOG_FILE` content into
  bats output before the test exits non-zero.
- **I-4**: The cardano-node container's host-published port is bound
  to `127.0.0.1` only — never `0.0.0.0`.
