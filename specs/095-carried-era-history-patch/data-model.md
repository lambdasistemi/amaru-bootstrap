# Data model

Artifact ceiling: 70 lines.

## D-095-PATCH-IDENTITY

One joined build identity with these immutable fields:

| Field | Source | Validation |
|---|---|---|
| upstream SHA | locked bare `pragma-org/amaru` input | Exactly 40 lowercase hex digits and exactly `ba992f65…`. |
| patch SHA-256 | repository patch bytes | Declared digest equals the computed digest. |
| package identity | Nix Amaru derivation | Exposes both upstream and patch identity; changes when either changes. |

## D-095-ERA-HISTORY-INPUT

| Field | Source | Validation |
|---|---|---|
| network | producer argument | Existing `NetworkName` parsing; custom fixture is `testnet_42`. |
| path | producer staging bundle | Exact staged `era-history.json`, present and previously validated. |
| effective history | built-in network history or loaded custom file | Custom network requires a readable, parseable file; its slot-to-epoch mapping must satisfy fixture snapshot selection. |

The data has no separate network identifier. “Wrong-network” proof therefore
uses a distinguishable epoch mapping and requires the real snapshot-selection
boundary to reject it; it does not claim an unavailable magic-number check.

## D-095-FIXTURE

PR 93 head `b52ca563624138cb09677b82bbb6ff5212197b00` contributes exact
`flake.lock` and `nix/peer-snapshots/resolution.json` blobs. The accepted branch
contains those exact blobs plus only the declared issue-95 integration delta.

## D-095-RETIREMENT-STATE

| State | Meaning |
|---|---|
| carried | Exact base and patch digests match; upstream equivalent is absent. |
| retire-required | Pin/base mismatch or equivalent upstream input is detected while patch remains. |
| retired | Patch removed, bare upstream identity proven, unchanged hosted boundary green. |
