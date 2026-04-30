# Bootstrap Producer

`bootstrap-producer` is the Phase 2 runtime deliverable. It is exposed
both as a Docker image and as a local flake app:

```bash
nix run .#bootstrap-producer -- \
  <chain-db> \
  <config-dir> \
  <bundle-dir> \
  <network>
```

## Invocation

The Docker image entrypoint is `bootstrap-producer`. The image does not
have a default `Cmd`, so Compose files must pass the four required
arguments:

```yaml
services:
  bootstrap-producer:
    image: ghcr.io/lambdasistemi/amaru-bootstrap-producer:<full-commit-sha>
    command:
      - /cardano/state/db
      - /cardano/config
      - /srv/amaru
      - testnet_42
    environment:
      AMARU_NETWORK: testnet_42
    volumes:
      - node-state:/cardano/state
      - node-configs:/cardano/config:ro
      - amaru-bundle:/srv/amaru
    restart: "no"
```

Argument 1 must be the actual cardano-node ChainDB directory as seen
inside the producer container. If the node stores its database at
`/state/db` and the state volume is mounted at `/cardano/state`, pass
`/cardano/state/db`. If the mounted path already is the database
directory, pass that path directly.

## Pipeline

The producer runs once and exits. Its exit code is the synchronization
signal for downstream Amaru services.

1. Check whether `<bundle-dir>/<network>` is already complete. If so,
   exit 0.
2. Validate the node config and wait for the chain DB to appear.
3. Poll `header-extractor tip-info` until the immutable tip is in
   Conway and at least two Conway epochs are available.
4. Run `ledger-state-emitter` at the selected target slot and the two
   preceding epoch slots.
5. Run `amaru convert-ledger-state` for all emitted ledger states.
6. Run `header-extractor list-blocks` and `get-header` to collect the
   headers Amaru needs.
7. Rewrite `nonces.json` so `tail` points at the previous-epoch header
   hash.
8. Run `amaru import-ledger-state`, `amaru import-headers`, and
   `amaru import-nonces`.
9. Atomically rename the unique temp directory into the final bundle
   path.

The final layout is:

```text
<bundle-dir>/<network>/
├── chain.<network>.db/
├── ledger.<network>.db/
├── snapshots/
├── nonces.json
└── headers/
```

The ledger store must contain `live/` plus at least three numeric
historical epoch directories. `amaru run` opens the live ledger and then
loads the two prior historical snapshots for rewards and leader-schedule
stake distribution. A bundle with only the latest imported snapshot can
pass `amaru import-ledger-state` and still fail to start.

The chain store must also contain the exact header for the ledger tip.
If the latest converted snapshot is
`snapshots/<slot>.<hash>.cbor`, the bundle must include
`headers/header.<slot>.<hash>.cbor` and import it into
`chain.<network>.db/`; otherwise `amaru run` fails during startup with
`ledger tip header not found`.

## Node-Release Target

This implementation targets `cardano-node 10.7.1`. The repository pins
that release through `cabal.project`, CHaP index states, the
`ouroboros-consensus` source-repository-package, and `flake.lock`.

This matters because Cardano ledger-state CBOR drifts between node
releases. The producer should be retargeted deliberately for each node
release instead of treated as a generic ledger-state serializer.

## Published Image

After the full CI workflow succeeds on `main`, the publish workflow
builds the Nix docker image, loads it into Docker, and pushes:

```text
ghcr.io/lambdasistemi/amaru-bootstrap-producer:<full-commit-sha>
```

The full commit SHA is the runtime integration contract. Downstream
compose files should pin the exact SHA they tested. The project does not
publish moving runtime tags such as `latest` for the producer.

The same tarball is available as the flake package
`.#packages.x86_64-linux.bootstrap-producer-image`. CI uploads it from
the Build Gate as an artifact named
`bootstrap-producer-image-<github-sha>`, containing
`amaru-bootstrap-producer-<github-sha>.tar.gz`.

To choose a concrete image, open the successful `main` CI run for the
commit you want, copy its full head SHA, then use the matching successful
`Publish bootstrap-producer image` workflow run. The GHCR image tag and
the uploaded artifact name both contain that same SHA.

## ChainDB Mount Contract

The producer must mount the cardano-node state volume read-write:

```yaml
volumes:
  - node-state:/cardano/state
  - node-configs:/cardano/config:ro
  - amaru-bundle:/srv/amaru
```

This is not a write contract for the producer. `header-extractor` opens
only the immutable DB and the readiness predicate is derived only from
immutable chunks. `ledger-state-emitter` opens the LedgerDB with an
in-memory backend and does not flush replayed state into the node-owned
LedgerDB. The read-write mount is required because the node-10.7.1
consensus ImmutableDB opener validates chunk files through APIs that
fail on a read-only filesystem.

## Ledger-State Projection

`ledger-state-emitter` writes the Amaru bootstrap projection of the
node-10.7.1 ledger state:

- UTxO entries are canonical `EncCBOR` entries, not consensus
  ledger-table `MemPack` bytes.
- The Shelley ledger wrapper is written in the pre-Peras shape that
  Amaru's converter walks.
- Conway/Dijkstra pool state is projected to the current pool params,
  future pool params, and retirements that Amaru imports.
- Conway/Dijkstra account state is projected into Amaru's legacy
  delegation-state wrapper while preserving rewards, deposits,
  stake-pool delegation, and DRep delegation.

The detailed contract is in
`specs/003-amaru-bootstrap-producer/research.md#r-011`.

## Verification

Local CI:

```bash
just ci
```

`just ci` includes the Build Gate, the Phase 0 smoke verdict, and the
Docker-level live verifier.

Producer-specific checks:

```bash
nix build .#checks.x86_64-linux.bootstrap-producer-synthesized
nix build .#checks.x86_64-linux.amaru-run-bootstrap
nix build .#checks.x86_64-linux.antithesis-short-epoch-samples
nix build .#checks.x86_64-linux.antithesis-short-epoch-golden
nix build .#checks.x86_64-linux.bootstrap-producer-bats
nix build .#checks.x86_64-linux.bootstrap-producer-image
just live-bootstrap-producer
```

`bootstrap-producer-synthesized` runs the real producer pipeline against
a synthesized Conway-ready `testnet_42` chain DB and verifies that Amaru
accepts the resulting ledger state, headers, and nonces.

`amaru-run-bootstrap` copies that produced bundle into a writable test
directory, starts `amaru run` without a live peer, and requires Amaru to
reach its `build_ledger` startup trace and remain alive until the test
timeout. This is the CI proof that the bundle is usable as Amaru startup
state, not only accepted by the import commands.

The synthesized fixture is not a mainnet ledger-content coverage test.
It proves the release-pinned CBOR projection can populate Amaru's stores
and that those stores are self-consistent at startup. It does not claim
to exercise every transaction, script, UTxO, stake, governance, or reward
shape a long-running public network can contain.

`antithesis-short-epoch-samples` generates a deterministic short-epoch
ChainDB corpus from the pinned node 10.7.1 tooling, emits the observed
early bootstrap slots `9`, `129`, and `249`, and converts them through
`amaru convert-ledger-state`. The source ChainDB is generated during the
Nix build; the repository does not commit bulky database artifacts.

`antithesis-short-epoch-golden` imports those converted snapshots into
Amaru's ledger store. It is the regression gate for the Antithesis
cold-start ledger-state family: convert success alone is not enough, the
same sampled states must also pass `amaru import-ledger-state`.

`just live-bootstrap-producer` is the Docker-level verifier. It seeds a
stock `testnet_42` ChainDB with `db-synthesizer`, starts
`ghcr.io/intersectmbo/cardano-node:10.7.1-amd64` on that DB, and
asserts that the bootstrap-producer can commit a complete bundle while
the official node has the ChainDB open.
