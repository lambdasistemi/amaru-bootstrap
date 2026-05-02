# Contract: Failure Classes & Test Output Shape

This document fixes the test's *observable contract*: which amaru log
substrings constitute fatal failures, the labels they map to, and the
exact shape of bats output on each failure mode. It is referenced by
FR-004, FR-006, and SC-004.

## Fatal log substrings

The test scans the *combined stdout+stderr* of the backgrounded
`amaru run` process (captured to `$AMARU_LOG_FILE`). On the **first**
match for any row below, the test fails — even if other rows would
also match elsewhere in the log.

| Class label | Literal substring (case-sensitive, `grep -F`) | Source in issue #34 |
|-------------|-----------------------------------------------|---------------------|
| `vrf`       | `Invalid VRF proof`                            | "ERROR amaru_consensus::stages::track_peers: chain_sync.validate_header.failed … Invalid VRF proof: VRF proof verification failed: VerificationFailed" |
| `consensus` | `Consensus died`                               | "ERROR amaru::cmd::run: Consensus died, this should not happen!" |
| `header`    | `HeaderValidationError`                        | "Failed to validate header at 364.… HeaderValidationError" |
| `rollback`  | `ledger inconsistency`                         | "ERROR amaru_consensus::stages::validate_block: ledger inconsistency: contains_point was true but rollback failed" |

These substrings are stable because they are produced by amaru's own
error-formatting code paths, not log macros that change formatting
across releases.

## Per-class bats output on failure

When a class match fires, the test must print, *before failing*:

```text
--- amaru consume failure: <class> ---
<line N-2>
<line N-1>
<line N: matching line>
<line N+1>
<line N+2>
--- end amaru consume failure ---
```

…where `<class>` is the class label and `N` is the 1-based line number
of the first match in `$AMARU_LOG_FILE`. Five lines of context
(±2 around the match) are sufficient — amaru's structured traces
include the relevant key/value context on the same line as the error
header.

## Per-class bats output on "exited early"

If `kill -0 "$AMARU_PID"` fails before the hold window elapses **and**
no fatal substring matched, the test prints:

```text
--- amaru consume failure: exited-early ---
amaru process exited before hold window (<elapsed>s of <hold>s)
--- amaru tail (last 50 lines) ---
<tail of $AMARU_LOG_FILE>
--- end amaru consume failure ---
```

…before failing. This makes US-2 acceptance scenario 3 concrete: an
unexpected clean exit is reported as its own class, not as a vague
timeout.

## Pass output (informational)

On a green run, the test should print one line summarising the hold:

```text
+ amaru ran cleanly for <hold>s, no fatal substrings matched
```

…analogous to the existing `+ era-readiness predicate satisfied`
informational line at line 149 of the current bats file.

## Order of checks

The test performs checks in this order, failing on the first that
fires:

1. **Liveness** — `kill -0 "$AMARU_PID"` after the hold window.
2. **Substring scan** — `grep -F -n -B2 -A2` against fatal substring
   table; first match wins.
3. **Pass** — print the success line.

This order means a process that crashed with a fatal substring still
gets the substring class label (more specific) rather than the
generic `exited-early` class — the substring scan will be performed
on the remnant log even though step 1 failed. (Implementation note:
step 1's failure path falls through to step 2 before failing the
test, so the scan happens regardless.)

## Non-goals (explicitly out of contract)

- **Whitelist matchers** ("must contain `build_ledger`"). Out of scope:
  the existing `amaru-run-bootstrap` flake check already proves
  startup; this test detects the absence of fatal classes during the
  hold window, not the presence of any positive signal.
- **Structured-trace JSON parsing**. Out of scope: amaru's
  `--with-json-traces` mode is available but adds parser complexity.
  Plain substring match is sufficient for the four classes above.
- **Header/slot-specific assertions** (e.g. "must reach slot N"). Out
  of scope per the spec's Assumption: diagnosing *why* a bundle fails
  belongs to issue #34's Asks 2 and 3, not this test.
