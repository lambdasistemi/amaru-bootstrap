# amaru-bootstrap

`amaru-bootstrap` builds the image and helper tools used to start
relay-only Amaru nodes on custom Cardano testnets.

## Current Shape

The repository used to be documented as a one-shot "bundle producer"
service. That is still a useful primitive, but it is no longer the
primary Antithesis integration shape.

The current Antithesis path runs the published
`ghcr.io/lambdasistemi/amaru-bootstrap-producer:<commit-sha>` image as
each long-lived `amaru-relay-N` container. Compose overrides the image
entrypoint to `amaru-relay-bootstrap`. That wrapper:

1. Writes `/startup/$RELAY_NAME.started` immediately for the Antithesis
   setup-complete gate.
2. Copies a fresh snapshot of the paired cardano-node `/live` state into
   private scratch space.
3. Invokes `/bin/bootstrap-producer` in a retry loop until the Amaru
   stores are complete.
4. Promotes the produced stores into `/srv/amaru`.
5. `exec`s `amaru run` against the paired cardano-node peer.

There is no downstream `depends_on: service_completed_successfully`
consumer in this relay mode. The `amaru-relay-N` process is the
bootstrapper and the Amaru node.

## Runtime Components

- `amaru-relay-bootstrap`: Antithesis relay entrypoint. It owns startup
  marker emission, retry policy, bundle promotion, and the final
  `amaru run` command.
- `bootstrap-producer`: one-shot primitive used by the relay wrapper and
  by local checks. It produces the Amaru ledger and chain stores from a
  cardano-node ChainDB.
- `ledger-state-emitter`: Haskell executable that projects a pinned
  cardano-node 10.7.1 ledger state into the legacy shape Amaru imports.
- `header-extractor`: Haskell executable for `tip-info`, `list-blocks`,
  and `get-header` against immutable ChainDB chunks.
- `amaru-runtime/`: deployment-provided runtime files consumed by
  `amaru run`: `era-history.json` and `global-parameters.json`.

## Production Pipeline

The production bootstrap pipeline is:

```text
cardano-node ChainDB
  -> ledger-state-emitter
  -> amaru convert-ledger-state
  -> header-extractor
  -> nonce tail rewrite
  -> amaru import-ledger-state/import-headers/import-nonces
  -> amaru run
```

`db-synthesizer` is not part of this runtime path. It remains available
for fixture generation and CI checks.

## Specs And History

The original active Spec Kit feature is
[`specs/003-amaru-bootstrap-producer/`](https://github.com/lambdasistemi/amaru-bootstrap/tree/main/specs/003-amaru-bootstrap-producer).
That spec describes the one-shot producer primitive. Later Antithesis
work layered the self-bootstrap relay contract on top of that primitive;
the relay wrapper's source comment names that downstream contract as
spec 080.

Historical bundle-shape notes are kept under
[History: What Amaru needed](history/what-amaru-needs.md). They explain
why the project originally replaced a forked `db-synthesizer`, but they
are not the current runtime recipe.

## How To Read This Site

- **[Tutorial](tutorial.md)** - wire the relay bootstrap image into a
  Compose testnet.
- **[Antithesis deployment](antithesis.md)** - topology, environment
  variables, startup marker contract, and runtime parameter files.
- **[Architecture](architecture.md)** - relay flow, producer pipeline,
  ChainDB contract, and state machines.
- **[Bootstrap producer](bootstrap-producer.md)** - lower-level
  one-shot producer contract and local verification commands.
- **[Constitution](constitution.md)** - project principles that govern
  design choices.

## Consumers

- [`cardano-foundation/cardano-node-antithesis`](https://github.com/cardano-foundation/cardano-node-antithesis)
  `cardano_amaru*` testnets pin commit-SHA-tagged images from this
  repository and run them as relay-only Amaru nodes.
