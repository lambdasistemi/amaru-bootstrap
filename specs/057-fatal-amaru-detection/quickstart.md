# Quickstart: Verify Fatal Amaru Detection

## Deterministic flake proof

```bash
nix build .#checks.x86_64-linux.bootstrap-producer-bats
```

The check covers every fatal class, the direct cleanliness return contract,
missing-log behavior, and the helper-reachability audit.

## Live consume boundary

With Docker available:

```bash
just live-bootstrap-producer
```

The verifier builds and loads the producer image, starts cardano-node 10.7.1,
produces the bundle from its open ChainDB, then runs the image's pinned Amaru
against the same node for the configured hold window.

Override only the duration when a longer observation is needed:

```bash
BOOTSTRAP_LIVE_AMARU_HOLD_SECONDS=120 just live-bootstrap-producer
```

No fatal signature is tolerated. If upstream issue
`pragma-org/amaru#1095` reproduces, retain the classified failure evidence and
escalate; do not whitelist or suppress it.

## Full proof

```bash
just ci
```

This remains the local mirror of the Build Gate, Phase 0 verdict, and Docker
live verifier.

