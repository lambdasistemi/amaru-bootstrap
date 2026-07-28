# Contract: Fatal Amaru Log Cleanliness

The check consumes a readable combined Amaru stdout/stderr log. It returns
success only when no fatal signature matches.

## Fatal classes

| Class | Literal case-sensitive substring |
|---|---|
| `vrf` | `Invalid VRF proof` |
| `consensus` | `Consensus died` |
| `header` | `HeaderValidationError` |
| `rollback` | `ledger inconsistency` |
| `future-rollback` | `roll back in the future` |

The future-rollback needle intentionally matches the stable core of messages
such as “attempted to roll back in the future”.

## Return contract

- `0`: the log exists, is readable, and contains no fatal signature.
- nonzero: the log is missing/unreadable or contains a fatal signature.

On a fatal match, stderr contains:

```text
--- amaru consume failure: <class> ---
<at most two lines before the first match>
<matching line>
<at most two lines after the first match>
--- end amaru consume failure ---
```

The first class in table order wins when more than one signature appears.

## Required direct proof

Before the implementation slice can be accepted:

1. invoke the cleanliness check directly on a seeded log containing the real
   issue signature `Consensus died, this should not happen!`;
2. record its nonzero exit and `consensus` diagnostic;
3. invoke the same check on clean Amaru output;
4. record its zero exit.

A passing Bats assertion about an inverted low-level scanner is not a
substitute for these two direct runs.

## Live observation order

Each live poll:

1. refreshes the combined container log;
2. runs the cleanliness check;
3. if clean, checks container liveness;
4. continues until the configured hold duration has elapsed.

This order preserves a fatal class when a container emitted the signature and
then exited. An early exit with no fatal match uses the existing
`exited-early` diagnostic contract and includes a bounded log tail.

