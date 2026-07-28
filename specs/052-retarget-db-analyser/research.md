# Research: Retarget Producer at db-analyser

The detailed measurements are frozen in the public
[replacement assessment](https://github.com/lambdasistemi/amaru-bootstrap/blob/explore/header-extractor-via-db-analyser/.llm/header-extractor-vs-db-analyser.md).
This ticket consumes those findings; it does not repeat the experiment.

## R-001: Use the no-analysis tip query

**Decision**: Poll the pinned `db-analyser` with no analysis flag and with
`--db-validation minimum-block-validation`.

**Evidence**: The assessment measures this path at 0.087 seconds versus 0.115
seconds for `header-extractor tip-info`. Both pay the same immutable database
open cost. `--count-blocks` still walks every secondary-index entry, and
`--show-slot-block-no` costs about 140 microseconds per block.

**Rationale**: The readiness loop needs only the immutable tip slot. The
no-analysis mode is the smallest and cheapest upstream path that prints it.

**Alternatives considered**:

- `--count-blocks`: rejected because it adds an unnecessary linear index walk.
- `--show-slot-block-no`: reserved for the one-shot target extraction because
  using it in the poll would reintroduce a whole-chain scan on every tick.

## R-002: Extract only the six required points in one forward pass

**Decision**: After a real tip identifies the three completed epoch numbers,
run one `--show-slot-block-no` pass, retain the previous stream record, and
write three target objects containing the epoch-tail point and its parent.

**Evidence**: The assessment proves that the producer's four readers of
`preflight-blocks.json` reduce to exactly three epoch tails and their three
immediate parents. Its measured prototype produces byte-identical
`targets.json` for the synthesized fixture:

| epoch | target slot | target hash | parent point |
|---:|---:|---|---|
| 1 | 172731 | `e1fb2a7b5a5b01d9b2cb5f2a5b8e2559b6929c695abf7e523e3b3cf6d4c02278` | `172652.3420432a02ae631e3b3cfd2dcbac97b415144764bcb554b074092b9b2bbb9352` |
| 2 | 259176 | `dddf69466f866b9898024502f99efb0ed73daa65a2543c0e9c413f078318345e` | `259173.e945d6beed5f99be2f618e43d1fe063941ed9d2466fdae18e9345a8137f24ee8` |
| 3 | 345164 | `3102adf971aecbc9d47c12e3cf8b883c53b55f61ef19b5d377c91e9bd4c68342` | `345159.19fa713646ce859bc47756c47af2a04cb28cef4944331ef70be2f999883e881d` |

**Rationale**: Keeping only the needed records deletes a multi-megabyte
whole-chain JSON intermediate and turns the parent lookup into the previous
stream record.

**Alternative considered**: `--analyse-from` anchoring was measured and
rejected. Exact epoch-boundary slots are almost never occupied, so finding
anchors cost 598 probes (about 51 seconds) versus 1.842 seconds for one forward
pass.

## R-003: Treat origin as not ready

**Decision**: Parse only a concrete `Point (At ...)` tip. `Point Origin` yields
no slot and remains in the readiness loop.

**Evidence**: The pinned tool exits zero for both an absent and empty chain
database and prints `ImmutableDB tip: Point Origin`.

**Rationale**: Exit status alone cannot distinguish the exact state the
producer is waiting through. An explicit concrete-point parse fails closed.

## R-004: Make the point check capable of failing

**Decision**: Preserve the production-generated `.logs/targets.json` and add a
Nix check that compares its three records against all six frozen points. In the
same check, run the assertion against an empty array and require that control
to fail.

**Rationale**: This exercises the production parser against a real synthesized
chain database. It catches both upstream `Show` format drift and a vacuous
assertion that accepts zero parsed lines.

**Alternatives considered**:

- A test-only copy of the parser: rejected because production and test parsing
  could drift independently.
- Exit-status-only coverage: rejected because `db-analyser` can exit zero
  while the parser extracts nothing.

## R-005: Preserve the live boundary in the gate

**Decision**: Keep `just live-bootstrap-producer` in `gate.sh` after the Nix
and bats checks.

**Rationale**: The behavior change crosses a real cardano-node ChainDB
boundary and feeds a real Amaru bundle. Hand-built traces and synthesized
checks prove selection logic but cannot prove the containerized producer can
open the live node database and the pinned Amaru runtime can consume its
result.

## R-006: Reuse the committed deterministic bundle contract

**Decision**: Compare the post-change synthesized bundle with issue #50's
committed 49-path inventory, 31 deterministic hashes, and 18 explicitly named
RocksDB physical-file exclusions.

**Pre-change verification**: At branch base `3a06fc1`, the comparison completed
with exit code zero:

- all 49 expected regular-file paths were present;
- all 31 deterministic hashes matched;
- the exclusion and deterministic sets partitioned all 49 paths;
- the realized bundle NAR hash was
  `sha256-DSx1vh9q8cKLbHBAiMIk83BQgOoVZ9oE+X/n30RkkmM=`;
- apparent size was 202,227 bytes.

Raw combined output and timestamps are retained in the ticket's orchestration
handoff record. The reviewable contract itself lives in
`specs/050-remove-dead-emitter/baseline-bundle-*.{txt,sha256}`.

**Rationale**: RocksDB physical bytes are nondeterministic even for repeated
realizations of the same derivation. Exact inventory plus deterministic bytes
is the honest byte-equivalence criterion, backed by the semantic and live
checks.

## R-007: Widen only the dependency sweep

**Decision**: Include the image module, Haskell `test/` suite, `AGENTS.md`, and
the repository guide skill. Exclude generated `site/**`.

**Evidence**: The dependency sweep found that the issue's original fence
omitted files required to remove the image executable and its spec suite.
Decision 1, recorded under [`rulings/`](./rulings/), approves those five files.

**Rationale**: The producer image cannot satisfy the issue without the image
module, and current agent guidance must not advertise a deleted tool. The docs
deployment builds from MkDocs sources, so hand-editing tracked generated HTML
would add noise and belongs to a separate cleanup ticket.

## R-008: Retain `NodeConfig` without retaining the tool

**Decision**: Move the small exported `NodeConfig` path wrapper to the existing
`AmaruBootstrap` marker module before deleting `HeaderExtractor`.

**Rationale**: The issue and parent brief explicitly require the type to
remain. After sibling #50 removed its former consumer, it no longer justifies
the consensus-heavy library implementation or dependencies.
