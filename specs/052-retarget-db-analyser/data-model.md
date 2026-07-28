# Data Model: db-analyser Producer Retarget

## Immutable Tip Observation

Represents one readiness-poll result.

| State | Upstream text | Producer meaning |
|---|---|---|
| Origin | `ImmutableDB tip: Point Origin` | not ready |
| Concrete | `Point (At (Block {blockPointSlot = SlotNo S, ...}))` | tip slot `S` is available |
| Tool error | nonzero exit | retry, except classified read-only access exits 7 |
| Unparseable success | zero exit without a concrete point | not ready; the real-chain check catches pinned format drift |

Only the slot of a concrete observation enters readiness arithmetic. The tip's
era is intentionally absent because the producer validates the selected
snapshot points against the configured Conway start slot.

## Target Record

One of three consecutive completed epoch tails.

| Field | Type | Validation |
|---|---|---|
| `epoch` | non-negative integer | consecutive across all three records |
| `slot` | non-negative integer | belongs to `epoch`; last observed block in that epoch |
| `hash` | lowercase hexadecimal string | non-empty block hash from the same trace record as `slot` |
| `parent_point` | `<slot>.<hash>` string | immediately preceding trace record in chain order |

The three records encode six chain points: each record's target `(slot, hash)`
and its parent point.

## Readiness State Transition

```text
origin / no concrete tip
  -> WAIT

concrete tip with tip_epoch < 3
  -> WAIT

concrete tip with tip_epoch >= 3
  -> one forward extraction for epochs tip_epoch-3 .. tip_epoch-1
     -> fewer than three valid records: WAIT
     -> oldest target before conway_first_slot: WAIT
     -> three valid records at/after Conway: READY
```

## Artifact Lifecycle

| Artifact | Lifetime | Consumers |
|---|---|---|
| `.logs/tip-info.stderr` | operator diagnostic | readiness error handling |
| `.logs/preflight-points.stderr` | operator diagnostic | extraction triage |
| `.logs/targets.json` | producer run evidence | `phase_targets`, Nix exact-point check |
| staging `targets.json` | one producer attempt | Amaru snapshot arguments and sidecar naming |
| `preflight-blocks.json` | deleted | none |

The staging copy remains an internal work artifact and is removed before the
atomic bundle commit. The compact log copy remains available for diagnosis and
for the load-bearing synthesized-chain assertion.
