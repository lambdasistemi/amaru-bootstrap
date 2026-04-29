# Research: Amaru Bootstrap Producer

Notes for [`plan.md`](./plan.md). Each entry: **Decision** / **Rationale** / **Alternatives considered**.

## R-001: Header extraction without `pragma-org/db-server`

**Decision**: do NOT use [`pragma-org/db-server`](https://github.com/pragma-org/db-server). Instead, add a small `header-extractor` executable to this repo's existing `amaru-bootstrap.cabal`, ~80 lines of Haskell, that consumes `Ouroboros.Consensus.Storage.ChainDB` directly and exposes a CLI compatible with Arnaud's existing usage in [`amaru-loader.sh`](https://github.com/pragma-org/amaru/blob/main/docker/testnet/amaru-loader.sh):

```
header-extractor list-blocks --db <path> --config <cfg>
header-extractor get-header <slot>.<hash> --db <path> --config <cfg>
```

Output JSON shape mirrors db-server's `{"tag": "Found", "data": …}` so Arnaud's `jq` pipeline ports unchanged.

**Rationale**: research found [`pragma-org/db-server`](https://github.com/pragma-org/db-server) (latest main `31a1a409`) hard-pins `ouroboros-consensus ^>= 0.21`. Our project pins consensus `0.27.0.0` (`8e3afe10`) for the rest of the pipeline. Mixing them in one `cabal.project` triggers a solver conflict. The available paths:

1. **Patch db-server's consensus pin** — violates Principle I (we'd be carrying a fork)
2. **Use db-server in a separate isolated `cabalProject'`** — feasible but doubles the Haskell build surface AND chain DBs produced by 0.27's `db-synthesizer` may not be readable by 0.21's chain-DB code (V2InMemory layout was introduced after 0.21)
3. **Re-implement the two queries we need against consensus 0.27** — ~80 lines of Haskell, no fork, no version mismatch, fully under our control

Option 3 wins on Principle II grounds: we orchestrate, we don't extend stock tools. Reading a chain DB's blocks through `Cardano.Tools.DBAnalyser.Block.Cardano.mkProtocolInfo` (Phase 1's R-001 entry point) plus `Ouroboros.Consensus.Storage.ChainDB.iterate` is the same pattern db-analyser itself uses internally for its `--show-slot-block-no` command. We use only ~30% of db-server's surface (the CLI `query` subcommand with two operations), so the per-line cost of replication is far below the cost of carrying a forked dependency or wrangling a multi-project Cabal solver.

**Alternatives considered**:
- Use db-server with consensus 0.21 in a separate haskell.nix project — rejected for chain-DB-format incompatibility risk and double build surface
- Use db-analyser's existing `--show-slot-block-no` and `--show-block-header-size` flags as a substitute — rejected: those modes print summaries, not the raw header CBOR amaru consumes
- Write the header extraction logic inside the bootstrap-producer container's bash orchestrator, calling out to db-analyser repeatedly — rejected: orders of magnitude slower and fragile

## R-002: amaru import-* flags

**Decision**: invoke amaru's three import commands with the exact flag shapes Arnaud's `amaru-loader.sh` uses, verified against the SHA pinned in our [`flake.lock`](../../../flake.lock) (`d44d84cd9c7a25651c399be96525fe6389e86447`):

```
amaru import-ledger-state --network testnet_42 \
                          --ledger-dir <bundle>/testnet_42/ledger.testnet_42.db \
                          --snapshot-dir <bundle>/testnet_42/snapshots/

amaru import-headers      --network testnet_42 \
                          --chain-dir <bundle>/testnet_42/chain.testnet_42.db

amaru import-nonces       --network testnet_42 \
                          --nonces-file <bundle>/testnet_42/nonces.json \
                          --chain-dir <bundle>/testnet_42/chain.testnet_42.db
```

All paths are rooted at `<bundle>/<network>/`, matching [R-005](#r-005-bundle-path-layout-carrier-between-producer-and-amaru). Operator-side, this means `/srv/amaru/<network>/...`. Per Obs#3, this is the single canonical path convention used everywhere (R-002, R-005, data-model, docker-compose contract, the orchestrator's import calls).

**Rationale**: research confirmed all three commands and flags are present in amaru at our pinned SHA. No version drift since Phase 1.

**Alternatives considered**: none — these are the consumer contract Phase 2 binds to. If a future amaru release changes the flags, that's a Phase 2.5 ticket.

## R-003: ghcr.io push from a `runs-on: nixos` self-hosted runner

**Decision**: build the image with `nix build .#bootstrap-producer-image` (which evaluates [`nix/bootstrap-producer-image.nix`](../../../nix/bootstrap-producer-image.nix) → `pkgs.dockerTools.buildLayeredImage`), then `docker load -i ./result && docker push ghcr.io/lambdasistemi/amaru-bootstrap-producer:${{ github.sha }}`. No skopeo, no `nix copy`. Standard pattern used by [`cardano-foundation/cardano-node-antithesis/.github/workflows/publish-images.yaml`](https://github.com/cardano-foundation/cardano-node-antithesis/blob/main/.github/workflows/publish-images.yaml).

Workflow uses default `GITHUB_TOKEN` with `permissions: { packages: write }` — no separate `GHCR_TOKEN` secret required for same-org pushes.

**Rationale**: simplest path; proven on lambdasistemi's existing infrastructure; one workflow file change, no new secrets.

**Alternatives considered**:
- `skopeo copy docker-archive:./result docker://ghcr.io/...` — equivalent, slightly cleaner (no docker-daemon dep), but skopeo is an extra runtime input the existing workflows don't pull in
- `nix copy --to docker://...` — would require Nix's experimental docker output store; not a stable target
- Build via `docker build` from a Dockerfile — violates Principle IV (Nix-first)

## R-004: Image layout

**Decision**: `pkgs.dockerTools.buildLayeredImage` with these layers:

- Base: `pkgs.dockerTools.binSh` + `pkgs.coreutils` + `pkgs.jq` + `pkgs.bash`
- Layer 1: `ledger-state-emitter` (from `nix/header-extractor.nix`'s sibling exe — see [R-011](#r-011-ledger-snapshot-emitter-replaces-db-analyser--snapshot-converter))
- Layer 2: `header-extractor` (from `nix/header-extractor.nix`)
- Layer 3: `amaru` (from `nix/amaru.nix`)
- Layer 4: the orchestrator script (`scripts/bootstrap-producer.sh`)

`db-analyser` and `snapshot-converter` are **not** in the runtime image — they are replaced by `ledger-state-emitter` per R-011. They remain in `nix/iog-tools.nix` only as build-time inputs to flake checks (the Phase 0 smoke test still uses `db-analyser`).

Entrypoint = `["/scripts/bootstrap-producer.sh"]`, with `pkgs.bash` included in the image's `contents` so the script's `#!/usr/bin/env bash` shebang resolves. **Do not** use `["/bin/sh", "/scripts/bootstrap-producer.sh"]` — `/bin/sh` is `dash` on Debian/Ubuntu derivatives, which silently breaks `set -euo pipefail` (no `pipefail`), `[[ … ]]`, arrays, `<<<` here-strings, and other bashisms the orchestrator uses (Obs#1). The script's executable bit must be set (chmod +x in the layer build).

Image runs as root inside the container (no user account creation needed for this single-purpose container).

**Rationale**: layered images cache better — when only the orchestrator script changes (the most frequent change), only the top layer rebuilds and pushes. Heavy layers (consensus-built binaries) stay cached.

**Alternatives considered**: `pkgs.dockerTools.buildImage` (single layer) — simpler but every script change re-pushes the whole image (~hundreds of MB). Not worth it.

## R-005: Bundle path layout (carrier between producer and amaru)

**Decision**: write the bundle to `/srv/amaru/<network>/` inside the container, which is a docker volume mounted by the operator. Layout matches what Arnaud's amaru-loader produces (so amaru reads it without configuration change):

```
/srv/amaru/testnet_42/
├── chain.testnet_42.db/         (populated by amaru import-headers + import-nonces)
├── ledger.testnet_42.db/        (populated by amaru import-ledger-state)
├── nonces.json                  (composed by orchestrator from snapshot's nonces + tail rewrite)
├── snapshots/<slot>.cbor        (output of amaru convert-ledger-state, intermediate)
├── snapshots/nonces.<slot>.json (intermediate, source for the rewritten nonces.json)
└── headers/header.<slot>.<hash>.cbor   (multiple files, one per extracted header)
```

`/srv/amaru/<network>/` is the single mount point — operator declares one volume in compose, both producer and amaru consume it.

**Rationale**: matches Arnaud's existing convention so amaru reads it unchanged. Network name in the path (`testnet_42`) keeps multiple-network support open without additional layout work.

**Alternatives considered**:
- Flat `/srv/amaru/` without network subdirectory — simpler but assumes one network; revisiting is cheap
- Compressed bundle archive — pointless when both writer and reader are in the same docker-compose stack

## R-006: Wait-and-validate pre-flight order

**Decision**: pre-flight is a *live-input-aware* sequence, not a static structural check. The cardano-node may be a concurrent writer; the bootstrap step accommodates the fact that the chain DB grows under it. The wait predicate is era-aware (R-010), not slot-distance-from-genesis.

```
1. Output bundle dir
   - if `<bundle>/<network>/` exists and is internally complete (ledger.db,
     chain.db, nonces.json, headers/* all present): exit 0 immediately (FR-008
     reuse).
   - else if `<bundle>/<network>.tmp/` exists (crashed prior run): rm -rf it,
     continue.
   - else: ensure parent dir is writable.

2. Config file
   - `<config>.json` exists and is parseable; referenced genesis files exist.
   - Compute the era-readiness predicate (R-010): the era amaru consumes
     (Conway), its first slot from the Cardano era history, and the
     `epochLength` from shelley-genesis.

3. Chain DB (poll, do not fail-fast)
   - Wait until `<chain-db>/immutable/` exists and is non-empty (the cardano-
     node has started forging or syncing). Cap: 5 minutes wall-clock, exit
     class `cluster-not-ready` on timeout.
   - Wait until the era-readiness predicate (R-010) holds against the
     immutable tip (R-009 mechanism). Cap: 90 minutes wall-clock, exit
     class `chain-not-era-ready` on timeout. On a mainnet-mature node, this
     loop observes the predicate already-true on its first iteration and
     exits within milliseconds.

4. Tooling sanity (one-shot, fail-fast)
   - Runtime tools on PATH (catch image-corruption early).
```

Each pre-flight failure exits with a class-specific code per [the CLI contract](./contracts/bootstrap-producer-cli.md#exit-codes).

**Rationale**: there are two operator scenarios the bootstrap step must serve from the same code path:

- **Antithesis cold start**: a freshly-launched producer node forging a Conway-genesis chain. The chain has just begun; the era-readiness predicate is false; the bootstrap step waits ~10-20 wall-minutes (under simulator speedup) until two Conway epochs are on chain.
- **Mainnet mature**: an operator with a long-running cardano-node already deep into Conway. The predicate is already true at the first poll; the wait phase is a no-op; the bootstrap step proceeds within seconds.

A wait condition expressed as `tip ≥ 2 × epochLength` (chain-distance-from-genesis) gets the antithesis case right by accident and the mainnet case wrong: on mainnet the immutable tip is already millions of slots past `2 × epochLength`, but those first epochs are pre-Conway, so satisfying that condition does not guarantee the snapshot point is consumable by amaru. The era-aware predicate (R-010) gets both cases right.

**Alternatives considered**:
- Have the operator's compose stack include a pre-step that waits for the chain to mature, with the bootstrap step then running fail-fast — rejected: splits the wait logic across two services and makes failure attribution ambiguous
- Use a `healthcheck` on the cardano-node and gate the bootstrap step on the node being "healthy" — rejected: cardano-node's healthcheck does not encode era-readiness; would require a custom healthcheck script that does the same era-aware polling work outside the bootstrap container
- Skip the wait phase entirely and require the operator to point the bootstrap step at an already-mature chain DB — rejected: closes the antithesis cold-start scenario and makes the project's primary user (the antithesis testnet) the one that needs the most bespoke ceremony

## R-007: Atomic bundle commit + concurrency-safe temp dir

**Decision**: write the bundle to a *unique-suffixed* temp dir `<bundle>/<network>.tmp.<pid>.<random>/` and `mv -T <unique-tmp> <bundle>/<network>` at the end. `renameFile` is atomic on POSIX; `mv -T` invokes `renameat2(NOREPLACE)`. The unique suffix per process makes concurrent compose-up calls safe (Obs#4): two bootstrap-producer instances running against the same input + same output volume each have their own temp dir; the first to finish wins via `mv -T`; the loser's `mv -T` fails with `EEXIST`, at which point the loser re-runs pre-flight, observes the now-complete bundle for the same network, and exits 0 (FR-008 idempotency path).

Combined with FR-008 idempotency: pre-flight detects a complete `<bundle>/<network>/` on the volume and short-circuits. Stale temp dirs (`<bundle>/<network>.tmp.*`) from a fault-killed prior run can be left for inspection or pruned at orchestrator start; they cannot be confused for the canonical bundle.

**Rationale**: a single fixed `<bundle>.tmp/` would let two concurrent bootstrap-producer processes corrupt each other's intermediate state (one rm -rf's the other's in-progress dir, the surviving `mv -T` carries half-written content). The unique-suffix pattern eliminates that race without locks. We do not use file-level locks because:
- `flock` semantics across docker bind mounts are filesystem-dependent and brittle.
- The unique-temp + `mv -T` race-loser-detects-winner pattern degrades cleanly to "second runner exits 0 because the first's bundle is now valid for both".

**Alternatives considered**:
- File-level locking via `flock` — rejected: bind-mount semantics; an extra failure mode.
- Marker file like `_ready` — exactly what we don't want (`depends_on: service_completed_successfully` makes it unnecessary).
- Single fixed `<bundle>.tmp/` (the original Phase 1 pattern, applicable when there is only ever one writer) — rejected here because Phase 2's compose semantics permit, and antithesis fault injection might cause, multiple bootstrap-producer runs to overlap.

## R-008: CI workflow for image publishing

**Decision**: new workflow [`/.github/workflows/publish-bootstrap-image.yml`](../../../.github/workflows/publish-bootstrap-image.yml). Triggers on push to `main`. Steps:

1. checkout
2. cachix-action (warm the nix cache)
3. `nix build .#packages.x86_64-linux.bootstrap-producer-image`
4. `docker load -i ./result` (load the image tarball into the daemon)
5. `echo ${{ secrets.GITHUB_TOKEN }} | docker login ghcr.io -u ${{ github.actor }} --password-stdin`
6. `docker tag <local-tag> ghcr.io/lambdasistemi/amaru-bootstrap-producer:${{ github.sha }}`
7. `docker push ghcr.io/lambdasistemi/amaru-bootstrap-producer:${{ github.sha }}`

`runs-on: nixos`. `permissions: { contents: read, packages: write }`. Build Gate dependency added so the image only publishes if smoke-test-bats and bootstrap-producer-bats are both green.

**Rationale**: standard pattern; same workflow shape as `cardano-foundation/cardano-node-antithesis/.github/workflows/publish-images.yaml`.

**Alternatives considered**:
- Build on every PR — wasteful; PR builds use the image-build flake check (no push) which already verifies the image evaluates cleanly
- Tag with `${{ github.ref_name }}` (branch name) instead of SHA — violates FR-010 / Principle III

## R-009: Wait strategy — poll immutable DB tip-info

**Decision**: detect era-readiness by polling the immutable DB's tip slot *and* tip era from inside the orchestrator. Implementation: extend the `header-extractor` from R-001 with a `tip-info` subcommand returning JSON:

```
header-extractor tip-info --db <chain-db> --config <cfg>
{"slot": 156784921, "era": "Conway", "blockHash": "abc..."}
```

It opens the immutable DB read-only, returns the tip's slot, era, and block-hash as JSON on stdout, exits 0. Exit non-zero (with stderr message) if the immutable DB doesn't exist yet or is unreadable.

The orchestrator's pre-flight loop evaluates the era-readiness predicate (R-010):

```bash
deadline=$(( $(date +%s) + 90 * 60 ))     # 90-min wall budget
conway_first_slot=$(jq -r '.…' <"$CONFIG/era-history.json")  # see R-010
while :; do
  if info=$(header-extractor tip-info --db "$CHAIN_DB" --config "$CONFIG" 2>/dev/null); then
    slot=$(jq -r .slot <<<"$info")
    era=$(jq -r .era <<<"$info")
    if [ "$era" = "Conway" ] && [ "$((slot - 2 * epochLength))" -ge "$conway_first_slot" ]; then
      target_slot=$slot
      break
    fi
    echo "+ waiting for chain tip to be era-ready — slot=$slot era=$era conway_first=$conway_first_slot"
  else
    echo "+ waiting for chain DB to appear"
  fi
  [ "$(date +%s)" -ge "$deadline" ] && exit 2   # rc=2 chain-not-era-ready
  sleep 10
done
```

**Rationale**: simplest possible mechanism. Reading the immutable DB while another process writes to the volatile DB is safe because the immutable portion is append-only — once a chunk is finalised, it never mutates. `Ouroboros.Consensus.Storage.ImmutableDB.openDB` in read-only mode is precisely the API db-analyser uses for the same purpose. No chain-follower subscription, no consensus state-machine reasoning, no concurrent-reader contract negotiation with the writer.

Returning the tip's *era* alongside its slot is a small extension over the simpler `tip-slot` shape: the underlying `Ouroboros.Consensus.HardFork.Combinator` exposes per-block era tags, so the cost is one additional pattern-match on the tip's `EraIndex`.

The 10-second poll cadence is gentle on the cardano-node's I/O. The 90-minute wall-clock budget is sized for the antithesis cold-start case (2 Conway epochs ≈ 10-20 wall-min under simulator speedup, with 4×-9× margin for fault-injected slowdowns). On a mainnet-mature node the loop exits on its first iteration in well under a second.

**Alternatives considered**:
- Open a full ChainDB (volatile + immutable + ledger) read-only and use `getCurrentChain` — rejected: opening a writer's volatile DB concurrently is not a contract consensus advertises as safe; we'd be in undefined-behaviour territory
- Subscribe as a chain follower (`ChainDB.newFollower`) — rejected: requires the full ChainDB stack and per-block decoding of the entire chain, every poll. Massive overkill when we just need the tip slot+era.
- Run `db-analyser --analyse-only --show-slot-block-no` and parse stdout — rejected: db-analyser opens the database in a mode that conflicts with a concurrent writer; designed for offline post-mortem analysis
- Have the cardano-node write a `current-slot` / `current-era` marker file — violates Principle I (forks the node)
- Watch the file count in `<chain-db>/immutable/` and infer slots — rejected: chunk size varies across eras; brittle and indirect; cannot infer era at all from the filesystem layout

## R-010: Era-readiness predicate and snapshot-point selection

**Decision**: define the bootstrap step's "ready" criterion as a predicate over the immutable DB tip:

```
ready(tip) ≜ tip.era ≥ ERA_AMARU_CONSUMES
           ∧ tip.slot − 2 × epochLength ≥ ERA_AMARU_CONSUMES.firstSlot
```

`ERA_AMARU_CONSUMES` is currently `Conway` — locked at the SHA pinned in `flake.lock`'s `pragma-org/amaru` input. `ERA_AMARU_CONSUMES.firstSlot` is read from the Cardano era history derivable from the genesis files: byron-genesis sets the byron→shelley transition; shelley-genesis sets the shelley-era epoch length and protocol parameters; subsequent era-transition slots are computable from the protocol-parameters' `epochsBeforeGoal`-style fields. For known networks (mainnet, preprod, preview, antithesis testnet_42), the Conway-fork slot is a fixed integer derivable at orchestrator pre-flight time.

When `ready(tip)` first holds, the orchestrator binds `target_slot = tip.slot` and proceeds to the snapshot pipeline. By construction `target_slot` is the immutable tip — past the chain's volatility horizon (k blocks back from the chain's "real" tip in the volatile DB) — so no additional safety margin is needed.

**Rationale**: one predicate, two operator scenarios.

- **Mainnet**: `tip.era` has been Conway since epoch 507 (mainnet). Any current-mainnet immutable tip satisfies both clauses; the predicate is already true; the orchestrator does not enter the wait loop.
- **Antithesis testnet_42** (Conway-genesis): `Conway.firstSlot = 0`, so the second clause becomes `tip.slot ≥ 2 × epochLength`. The orchestrator waits for two epochs to forge.
- **Preprod / preview** (mid-life testnets): same as mainnet (already mature), no wait.
- **Hypothetical Conway-fresh testnet** (testnet that hard-forked to Conway recently): the orchestrator waits until two epochs of Conway have completed.

The snapshot point being the immutable tip means amaru receives the freshest available bundle every time, without any per-network safety-margin tuning.

**Alternatives considered**:
- `target_slot = tip.slot − safety_margin` for some configurable margin — rejected: redundant. The immutable tip *is* the safety horizon; volatile blocks aren't there to begin with.
- `target_slot = tip.slot − 1 × epochLength` for cosmetic alignment with epoch boundaries — rejected: forces an extra epoch of wait on antithesis cold-start with no consumer-side benefit.
- Compute era boundaries online from the chain itself rather than from genesis files — rejected: requires a full ledger replay; for known networks the era-history is a constant.
- Extend the predicate to require ≥3 or more preceding Conway epochs ("safety belt") — rejected: amaru's consumer requires 2 (one for snapshot's nonces, one for snapshot.previousEpoch.nonces); 3 is unprincipled.

## R-011: Ledger-snapshot emitter (replaces db-analyser + snapshot-converter)

**Decision**: build a small Haskell exe in this repo, `ledger-state-emitter`, that opens the chain DB at `target_slot` and writes a single CBOR file in the exact shape `amaru convert-ledger-state` expects to consume. This **replaces** the `db-analyser --store-ledger` + `snapshot-converter Mem -> Legacy` pair as the front of the snapshot pipeline. The orchestrator's `phase_dump` and `phase_emit` collapse into one `phase_emit` step.

**Release target**: the emitter is intentionally pinned to the `cardano-node 10.7.1` dependency set. `cabal.project` freezes the node-release-compatible CHaP and source-repository-package revisions, including `ouroboros-consensus` `release-ouroboros-consensus-3.0.1.0`. A successful compile against a random ledger dependency set is not sufficient: this producer emits the bootstrap projection for the node release named by the repository pins.

**Rationale**: the `db-analyser → snapshot-converter` pair produces a Legacy `ExtLedgerState` CBOR file in which the UTxO entries (`Map TxIn TxOut`) are serialised as raw CBOR byte strings via `defaultEncodeTablesWithHint`'s `MemPack` path:

```haskell
-- from Ouroboros.Consensus.Ledger.Tables
defaultEncodeTablesWithHint _ (LedgerTables (ValuesMK tbs)) =
  mconcat
    [ CBOR.encodeMapLen (fromIntegral $ Map.size tbs)
    , Map.foldMapWithKey (\k v ->
        CBOR.encodeBytes (packByteString k) <>     -- TxIn as MemPack bytes
        CBOR.encodeBytes (packByteString v))       -- TxOut as MemPack bytes
        tbs
    ]
```

`amaru convert-ledger-state` (and its consumer `amaru import-ledger-state`) expect TxOut entries in the canonical `EncCBOR (TxOut era)` shape — a CBOR map (modern, `{0:addr,1:value,2:datum,3:script}`) or array (legacy, `[addr,value,?datum]`), per `Cardano.Ledger.Babbage.TxOut.encCBOR`. amaru's `MemoizedTransactionOutput::decode` errors on a `Type::Bytes` input and the surrounding `import_utxo` loop converts that into `"end of input bytes"`. End-to-end repro under `/tmp/t019-diag/` (see PR thread).

`cardano-api`'s `encodeLedgerState` reuses `Shelley.encodeShelleyLedgerState` and produces the same MemPack-bytes output, so cardano-api does not help. The de-compaction step performed by `ogmios` (which amaru's [`data/fetch.mjs`](https://github.com/pragma-org/amaru/blob/main/data/fetch.mjs) treats as the canonical snapshot source) happens on ogmios's read path: it streams the GetCBOR result, `MemPack`-decodes each TxOut, then re-encodes via `cardano-ledger`'s `EncCBOR` instance. We mirror that read-path locally.

**Implementation**:

```
ledger-state-emitter \
    --db <chain-db> \
    --config <node-config.json> \
    --target-slot <SLOT> \
    --out <output.cbor>
```

1. `mkProtocolInfo` from `Cardano.Tools.DBAnalyser.Block.Cardano` (already in `cabal.project`, used by `header-extractor`'s `tipInfo`).
2. Open the LedgerDB read-only in V2InMemory mode at `target_slot` — same code path `db-analyser --store-ledger` uses internally.
3. Extract the in-memory `ExtLedgerState blk EmptyMK` and the `LedgerTables blk ValuesMK` (UTxO).
4. Emit a CBOR file whose outer envelope is identical to `encodeDiskExtLedgerState` (version + ext-ledger-state telescope + tip + chain-dep-state), but where the UTxO tables go through a custom encoder:

```haskell
-- pseudocode of the only deviation from consensus's default
encodeUtxoForAmaru utxo =
  encodeMapLen (Map.size utxo) <>
  Map.foldMapWithKey (\txin txout ->
    encCBOR txin <> encCBOR txout)        -- standard cardano-ledger EncCBOR
    utxo
```

The rest of the file (HFC telescope, `ChainDepState`, `AnnTip`, era bounds) is byte-identical to consensus's Legacy output, so amaru's existing `convert-ledger-state` parser walks it unchanged.

**Amaru bootstrap projection for node 10.7.1**:

- `UTxOState` uses canonical `EncCBOR` for `TxIn` and `TxOut` entries instead of the consensus ledger-table `MemPack` shortcut.
- The Shelley ledger wrapper omits the node-10.7.1 Peras certificate field because Amaru's converter slices the ledger state through the pre-Peras wrapper shape.
- Conway/Dijkstra `PState` is projected from the node-10.7.1 four-field shape to Amaru's imported three-field shape: current pool parameters, future pool parameters, retirements. The node-side VRF-key index is an internal acceleration structure.
- Conway/Dijkstra `DState` is projected from the node-10.7.1 account-state map into Amaru's legacy delegation-state wrapper. Balance, deposit, stake-pool delegation, and DRep delegation are preserved; pointer indexes and the intermediate deposits accumulator are placeholders because Amaru skips those fields during bootstrap.

**Where the boundary sits**: `amaru convert-ledger-state` stays in the pipeline. We deliberately do **not** absorb its work (slicing the inner ledger state + producing `nonces.<slot>.<hash>.json` + `history.<slot>.<hash>.json`). Reasons captured:

- Three contracts vs. one. `import-*` consumes a CBOR snapshot AND a separate `history.json` (read by `make_era_history` for testnets) AND a separate `nonces.json`. Producing all three ourselves means owning amaru's `serde::Serialize` JSON shapes for `EraHistory`, `EraSummary`, `EraBound`, `InitialNonces`, `Point`, `Nonce`, `HeaderHash`. Keeping `convert-ledger-state` lets amaru's upstream Rust types stay the source of truth; we own one CBOR contract instead of three.
- Failure attribution. If `import-ledger-state` errors on the converted file, the bug is upstream of our code. If we emit all three, every category of failure becomes our problem.
- Cost. `convert-ledger-state` is a single CBOR pass over a ~16 KB file. Not a bottleneck.

**Image layout impact (R-004 update)**: the runtime image drops `db-analyser` and `snapshot-converter` from its layers and adds `ledger-state-emitter`. Net layer count unchanged; net runtime image size smaller (one Haskell binary replaces two).

**Test surface**: T019b adds the flake check `bootstrap-producer-synthesized`, which runs the real producer pipeline against the synthesized Conway-ready chain DB and asserts that `amaru convert-ledger-state`, `amaru import-ledger-state`, `amaru import-headers`, and `amaru import-nonces` all succeed.

**Alternatives considered**:
- **Patch consensus's `defaultEncodeTablesWithHint` to emit canonical CBOR** — violates Principle I (we'd be carrying a fork of consensus).
- **Patch amaru's `MemoizedTransactionOutput::decode` to also accept `Type::Bytes` (MemPack form)** — clean upstream PR; we'll file it for the long term, but it can't gate this project's deliverable. Even if accepted, downstream users on older amaru versions would still hit the gap.
- **Run `ogmios` in the bootstrap-producer image as a sidecar to the cardano-node** — Principle-II compliant but doubles the image surface (ogmios + node), requires cardano-node IPC plumbing inside the producer, and replaces a 150-line Haskell tool with a multi-process service for no semantic benefit.
- **CBOR-to-CBOR converter as a post-process on snapshot-converter's output** — feasible but more brittle: requires byte-surgery on the embedded UTxO map mid-stream, and embeds knowledge of cardano-ledger's `MemPack` format into our orchestrator. The emitter approach goes through the typed Haskell API directly.
- **Skip `amaru convert-ledger-state` and emit all three artifacts directly** — see "Where the boundary sits" above; rejected on contract-surface grounds.
