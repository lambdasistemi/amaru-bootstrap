# Single source of truth for the deliberate peer-snapshot faults (I1/I2/I3).
#
# nix/amaru.nix accepts exactly these (plus null) as `peerSnapshotFault`, and
# flake.nix builds exactly one negative-control variant per entry. Keeping one
# list means a fault cannot be dropped from the permanent negative control
# while still looking supported.
[
  "missing-mainnet"
  "invalid-schema-preprod"
  "wrong-magic-preview"
  "empty-pools-mainnet"
  "tampered-staged-mainnet"
]
