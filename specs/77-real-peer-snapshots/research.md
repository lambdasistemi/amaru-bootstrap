# Research — upstream peer-snapshot resolution rule

Issue: #77. All findings read from the pinned amaru flake input
(`pragma-org/amaru@437ff6c4fb506e1347eee9e619271a5ccb55a401`, read-only);
nothing was asked of upstream.

## R-RULE — the exact resolution rule in build.rs

Source: `crates/amaru-node/build/peer_snapshot.rs` (called from
`crates/amaru-node/build/build.rs`).

1. **Timestamp**: `amaru_head_committer_date()` runs
   `git show -s --format=%cI HEAD` in `CARGO_MANIFEST_DIR`
   (`crates/amaru-node`) — i.e. the **committer date** (`%cI`, strict
   ISO-8601 with the committer's original UTC offset) of the amaru HEAD
   commit. For a GitHub flake input this equals `flake.lock`'s
   `lastModified` for the `amaru` node (Unix committer time).
2. **Rev selection**: `resolve_configs_commit()` issues
   `GET https://api.github.com/repos/cardano-foundation/cardano-configurations/commits?until=<ISO>&per_page=1`
   — no `sha` parameter, so GitHub filters the **default branch** (`main`);
   `until` filters on **committer date**. The result is the youngest
   default-branch commit with committer date <= the amaru HEAD committer
   date. Only `+` is percent-encoded in the timestamp (`urlencoding_until`).
3. **File fetch**: `download_snapshot()` gets
   `https://raw.githubusercontent.com/cardano-foundation/cardano-configurations/<sha>/network/<network>/cardano-node/peer-snapshot.json`
   for each network in `amaru_kernel::PEER_SNAPSHOT_NETWORKS`
   (`crates/amaru-kernel/src/cardano/network_name.rs:34`:
   Mainnet, Preprod, Preview).
4. **Staging + embed**: files are staged at
   `crates/amaru-node/config/peer-snapshots/<network>/peer-snapshot.json`,
   then `fs::copy`'d to `OUT_DIR/peer_snapshot_<network>.json` and embedded
   via a generated `embedded_peer_snapshots.rs` (`include_bytes!`). The
   staged file is never parsed at build time — bytes are embedded verbatim.
5. **Provenance**: the generated constant `CONFIGS_COMMIT` is
   `Some(<sha>)` when a `CONFIGS_COMMIT_CACHE` file (line format
   `sha: <sha>`) is staged next to the network dirs, else `None`. Under
   `AMARU_SKIP_PEER_SNAPSHOT_FETCH=1` the sha comes **only** from that cache
   file (`peer_snapshot.rs` line 76).
6. **Skip flag**: `AMARU_SKIP_PEER_SNAPSHOT_FETCH` accepts exactly
   `1|true|TRUE|yes|YES`; with it set, no network access is attempted and
   staged files are used as-is. Presence of a staged file per network is
   enforced unconditionally (`bail!` otherwise).

## R-RESOLVED — rule applied to the current pin

- amaru pin `437ff6c4fb506e1347eee9e619271a5ccb55a401`, committer date
  `2026-07-29T07:56:00Z` (= `flake.lock` `lastModified` 1785311760; confirmed
  identical via the GitHub commits API).
- Rule selects `cardano-foundation/cardano-configurations`
  `4a9b69103507b124679fcb185eeabd4dc15e9c75` (committer date
  `2026-07-16T03:10:52Z`, branch `main`).
- Files at that rev (sha256, size, bigLedgerPools count):
  - mainnet `2e0c42572060c6c4edc95907977195f08e5880d521206436134237493ba274de`
    152950 B, 470 pools, NetworkMagic 764824073
  - preprod `e57179665f4854f46b4a5171a65869c2dbd7f515fb083dcffa76f364c41b9d7b`
    12949 B, 52 pools, NetworkMagic 1
  - preview `314d8f63dfedbc0b980c6fcedac56cab2f58fb0659e1e313fa844ca75b49bff0`
    19688 B, 80 pools, NetworkMagic 2

## R-CLEAN — cleanCargoSource interaction

`craneLib.cleanCargoSource` drops non-cargo files from the build src, so
staging must happen in `preBuild` (as today) and schema/validation inputs
must be read from the raw `${amaru}` input path, not the cleaned src.

## R-TZ — timezone subtlety

`%cI` preserves the committer's local offset; GitHub's `until` compares
instants, so the UTC form from `lastModified` is equivalent. Automation may
use `flake.lock` `lastModified` (UTC) directly.

## R-VALIDATOR — schema validation tool

`peer-snapshot.schema.json` is draft 2020-12. nixpkgs `check-jsonschema`
supports it and runs fully offline inside the build sandbox.
