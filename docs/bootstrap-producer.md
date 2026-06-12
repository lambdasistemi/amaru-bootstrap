# Bootstrap Producer

`bootstrap-producer` is the lower-level one-shot primitive inside the
published image. The current Antithesis deployment usually runs the same
image with `entrypoint: amaru-relay-bootstrap`; that relay wrapper calls
`/bin/bootstrap-producer` internally and then `exec`s `amaru run`.

Use this page for local debugging, CI checks, and standalone producer
integration. Use [Tutorial](tutorial.md) or
[Antithesis deployment](antithesis.md) for the relay container shape.

The producer is also exposed as a local flake app:

```bash
nix run .#bootstrap-producer -- \
  <chain-db> \
  <config-dir> \
  <bundle-dir> \
  <network>
```

## Standalone Invocation

The Docker image default entrypoint is `bootstrap-producer` for
standalone compatibility. The image does not have a default `Cmd`, so a
standalone Compose service must pass the four required arguments:

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

The producer runs once and exits. In standalone integrations its exit
code can be used as the synchronization signal for downstream Amaru
services. In Antithesis relay integrations, the synchronization signal is
the relay startup marker and the relay process continues as `amaru run`.

1. Check whether `<bundle-dir>/<network>` is already complete. If so,
   exit 0.
2. Validate the node config and genesis (`config.json`,
   `shelley-genesis.json`, positive `epochLength`) and wait for the
   chain DB to appear.
3. Poll `header-extractor tip-info` until the era-readiness predicate
   holds: the immutable tip is in Conway, the tip epoch is at least 3,
   and `header-extractor list-blocks` finds a block in each of the
   three most recent completed epochs, all at or after the Conway fork
   slot. The snapshot targets are the last immutable block of each of
   those three epochs.
4. Compose `targets.json` (epoch/slot/hash/parent_point) and
   `snapshots.json` from the chain's own block list, bypassing Koios.
5. Run `amaru create-snapshots` with `--targets-file` and an isolated
   `--cardano-db-dir` (immutable chunks symlinked from the source
   chain DB), materializing one snapshot directory per epoch with
   packaged bootstrap headers.
6. Write a `history.<slot>.<hash>.json` era-history sidecar next to
   each snapshot and an `era-history.json` at the bundle root, both
   built from the genesis `epochLength`.
7. Run `amaru bootstrap`, which populates `ledger.<network>.db` and
   `chain.<network>.db`, deriving nonces from the latest snapshot and
   importing the packaged headers.
8. Atomically rename (`mv -T`) the unique staging directory into the
   final bundle path.

The final layout is:

```text
<bundle-dir>/
├── .logs/                      # per-phase stderr logs
└── <network>/
    ├── chain.<network>.db/
    ├── ledger.<network>.db/
    ├── snapshots/<network>/
    └── era-history.json
```

Nonces and bootstrap headers are baked into `chain.<network>.db` by
`amaru bootstrap`; they are no longer separate bundle artefacts.

The ledger store must contain `live/` plus at least three numeric
historical epoch directories. `amaru run` opens the live ledger and then
loads the two prior historical snapshots for rewards and leader-schedule
stake distribution.

For custom testnets, `amaru bootstrap` reads the
`history.<slot>.<hash>.json` sidecar next to each snapshot directory.
Without it, Amaru defaults to the built-in testnet era history
(epoch size 86400) and computes wrong nonces on short-epoch networks.
The bundle-root `era-history.json` is the same document, shipped for
`amaru run --era-history-file` at consume time. The runtime
`era-history.json` and `global-parameters.json` consumed by `amaru run`
in relay mode are deployment files mounted at `/amaru-runtime`; see
[Antithesis deployment](antithesis.md#runtime-parameter-files).

### Environment Knobs

| Variable | Default | Meaning |
|----------|---------|---------|
| `AMARU_NETWORK` | 4th positional argument | Overrides the network name. |
| `AMARU_CLUSTER_READY_DEADLINE_SECONDS` | `300` | Deadline for the chain DB to appear (exit 1 past it). |
| `AMARU_WAIT_DEADLINE_SECONDS` | `5400` | Deadline for the era-readiness predicate (exit 2 past it). |
| `AMARU_POLL_INTERVAL_SECONDS` | `10` | Sleep between readiness polls. |

The relay wrapper tightens the two deadlines to 30 seconds and the poll
interval to 5 seconds, because its outer retry loop is the right place
to wait for the chain to mature.

### Exit Codes

| Code | Class |
|------|-------|
| 0 | success (bundle committed, or an existing complete bundle found) |
| 1 | cluster-not-ready: chain DB never appeared |
| 2 | chain-not-era-ready: readiness predicate never held |
| 3 | configuration-error: missing/invalid config or genesis |
| 5 | tool-error: targets composition failed |
| 6 | tool-error: `amaru create-snapshots` or sidecar write failed |
| 7 | tool-error: `header-extractor` could not read the chain DB (for example a read-only mount) |
| 9 | tool-error: `amaru bootstrap` failed |
| 10 | output-write-error: atomic rename failed |
| >= 64 | internal error (bash `ERR` trap: `64 + rc`) |

Every tool invocation's stderr lands in `<bundle-dir>/.logs/<phase>.stderr`,
and the producer tails the failing phase's log onto its own stderr.

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

After the full CI workflow succeeds on a same-repository pull request,
the same workflow publishes immutable PR test tags:

```text
ghcr.io/lambdasistemi/amaru-bootstrap-producer:<full-pr-head-sha>
ghcr.io/lambdasistemi/amaru-bootstrap-producer:pr-<pr-number>-<full-pr-head-sha>
```

The full commit SHA is the runtime integration contract. Downstream
compose files should pin the exact SHA they tested. The project does not
publish moving runtime tags such as `latest` for the producer.

The same tarball is available as the flake package
`.#packages.x86_64-linux.bootstrap-producer-image`. CI uploads it from
the Build Gate as an artifact named
`bootstrap-producer-image-<github-sha>`, containing
`amaru-bootstrap-producer-<github-sha>.tar.gz`.

To choose a concrete image, open the successful `main` or
same-repository PR CI run for the commit you want, copy its full head
SHA, then use the matching successful `Publish bootstrap-producer image`
workflow run. The GHCR image tag and the uploaded artifact name both
contain that same SHA.

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
immutable chunks. `amaru create-snapshots` works against an isolated
`--cardano-db-dir` in which the immutable chunks are symlinked from the
source chain DB, so the ledger snapshots its `db-analyser` engine
materializes never land in the node-owned LedgerDB. The read-write
mount is required because the node-10.7.1 consensus ImmutableDB opener
validates chunk files through APIs that fail on a read-only filesystem;
the producer detects that case and exits 7 with a pointer to the
`tip-info` stderr log.

## Ledger-State Projection (standalone emitter)

`ledger-state-emitter` is the in-repo projection tool. It is no longer
invoked by the producer pipeline (upstream `amaru create-snapshots` +
`amaru bootstrap` own snapshot materialization now), but it remains in
the image and as the flake app `nix run .#ledger-state-emitter` for
standalone emission and debugging. It writes the Amaru bootstrap
projection of the node-10.7.1 ledger state:

- UTxO entries are canonical `EncCBOR` entries, not consensus
  ledger-table `MemPack` bytes.
- The Shelley ledger wrapper is written in the pre-Peras shape that
  Amaru's converter walks.
- Conway/Dijkstra pool state is projected to the current pool params,
  future pool params, and retirements that Amaru imports.
- Conway/Dijkstra account state is projected into Amaru's legacy
  delegation-state wrapper while preserving rewards, deposits,
  stake-pool delegation, and DRep delegation.
- Empty reward-update state is projected as a completed zero reward
  update because Amaru's import command decodes snapshots with
  `has_rewards=true`.

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
a synthesized Conway-ready `testnet_42` chain DB and asserts the
canonical bundle layout: a ledger store with `live/` plus at least three
numeric historical snapshots, a chain store, and the bundle-root
`era-history.json`.

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
(`epochLength=120`) ChainDB corpus from the pinned node 10.7.1 tooling,
runs the full producer pipeline against it, and asserts that at least
three snapshot directories and the bundle-root `era-history.json` were
materialized. The source ChainDB is generated during the Nix build; the
repository does not commit bulky database artifacts.

`antithesis-short-epoch-golden` is the issue #29 regression gate for the
Antithesis cold-start family. It starts `amaru run` on the short-epoch
bundle with `--era-history-file` pointing at the bundle's
`era-history.json` (the network built-in epoch size is 86400), and
requires Amaru to reach `build_ledger` and stay alive until the test
timeout. Bundle production alone is not enough; the short-epoch stores
must also be usable as Amaru startup state.

`just live-bootstrap-producer` is the Docker-level verifier. It seeds a
stock `testnet_42` ChainDB with `db-synthesizer`, starts
`ghcr.io/intersectmbo/cardano-node:10.7.1-amd64` on that DB, and
asserts that the bootstrap-producer can commit a complete bundle while
the official node has the ChainDB open.
