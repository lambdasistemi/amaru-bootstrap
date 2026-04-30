# Feature Specification: Amaru Bootstrap Producer

**Feature Branch**: `003-amaru-bootstrap-producer`
**Created**: 2026-04-28
**Status**: Draft
**Input**: User description: "Phase 2: amaru-bootstrap-producer container that follows a cardano-node's chain DB, snapshots once the immutable tip is era-stable for amaru's consumer (Conway), and exits 0; Amaru containers depends_on it via service_completed_successfully"

## User Scenarios & Testing *(mandatory)*

### User Story 1 — An operator brings up Amaru next to an existing cardano-node (Priority: P1)

An operator already runs a cardano-node — either a long-syncing mainnet node, a relay on preprod, or a producer node in the antithesis testnet's compose stack. They want to add Amaru to the same machine without performing any pre-snapshot ceremony of their own. They drop the bootstrap-producer container into their compose alongside their existing node, point its chain DB mount at the node's chain DB, and `docker compose up`. The bootstrap step opens the chain DB, reads its immutable tip, decides whether the chain is mature enough for amaru to consume (i.e. the tip is in the era amaru implements *and* the snapshot point has at least two preceding epochs of that era available for nonce computation), and:

- if **yes** (typical mainnet, late-running preprod, or an antithesis cluster that has organically forged ≥2 Conway epochs): the bootstrap step runs the snapshot pipeline immediately and exits 0 within minutes.
- if **not yet** (typical antithesis cold start from a Conway-genesis testnet): the bootstrap step *waits* — polling the immutable tip — until the chain has matured enough, then snapshots and exits 0.

Either way the operator does the same thing: they run `docker compose up` and Amaru starts when ready. The contract is: **bootstrap exits cleanly ⇔ Amaru is ready to run**.

**Why this priority**: This is the entire point of Phase 2. Phase 0 + 1 validated the format pipeline as a CI smoke test against a precomputed chain DB; this packages it as a service that any operator with a running cardano-node can use, including the antithesis testnet (where the chain forges from Conway-genesis) and a real-world mainnet operator (where the chain is already deep into Conway). Without this, Amaru can be bootstrapped only by the original Phase 1 workflow, which assumes an offline, fully-synthesized chain DB and does not work in either of the live cases.

**Independent Test**: An operator with the project checked out runs `docker compose up` on a stripped-down test compose file (one cardano-node + the bootstrap-producer + an Amaru service). On the antithesis fixture this includes the wait phase (~10-20 wall-minutes under simulator speedup). On a real mainnet node already past the Conway hard fork, it does NOT include a wait phase — the bootstrap step proceeds straight to the snapshot pipeline. In both cases Amaru reaches running phase without operator intervention. No other functionality of the project needs to exist for this story to be testable.

**Acceptance Scenarios**:

1. **Antithesis cold start.** Given a compose stack with a freshly-started producer node forging from a Conway-genesis testnet plus the bootstrap-producer plus one or more Amaru services depending on the bootstrap step's success, when the operator starts the stack, then the bootstrap step waits while the producer forges blocks, snapshots once at least two Conway epochs are on chain, exits 0, and the Amaru services start exactly when the bundle is complete on the shared volume.

2. **Mainnet operator.** Given a compose stack on a host where a cardano-node has been running and is currently caught up with mainnet (chain tip well past the Conway hard fork), when the operator brings up the bootstrap-producer + Amaru services, then the bootstrap step does NOT enter any wait phase — it inspects the immutable tip, finds it is in Conway with ≥2 Conway epochs of history, runs the snapshot pipeline within a few minutes, and Amaru starts.

3. **Stale prior bundle.** Given the bootstrap step has already produced a complete bundle on the shared volume during a prior compose run, when an Amaru service is killed and respawns under fault injection, then the bootstrap step does NOT re-run; the existing bundle on the volume is reused, and Amaru recovers using the same bundle it had before the kill.

4. **Multiple consumers.** Given two Amaru services depending on the same bootstrap step, when the bootstrap step succeeds, then both Amaru services receive identical bundle data from the shared volume and start independently of each other.

5. **Failure attribution.** Given the bootstrap step fails midway through (any reason — chain DB unreachable, the chain has not yet entered Conway and the wait deadline elapses, malformed config, snapshot pipeline tool failure), when the operator inspects the running stack, then the bootstrap step has exited non-zero with an exit code that distinguishes the four failure classes, and the Amaru services have not started.

---

### Edge Cases

- **Partial bundle written**: the bootstrap step completes some pipeline phases then crashes. The bundle on the volume must NOT be mistaken for a complete one — the success signal must be all-or-nothing.
- **Chain in pre-Conway era**: the operator's cardano-node has been running but the chain is still in Byron/Shelley/Allegra/Mary/Alonzo/Babbage. The bootstrap step must report this distinctly (rather than treating the chain as too short) so the operator understands that *time*, not chain growth, is what the cluster needs.
- **Chain crossed Conway only recently**: the immutable tip is in Conway but the previous two epochs are partly pre-Conway. The snapshot point's nonce computation requires two preceding epochs *of the consumed era*. The bootstrap step must wait until that history is available, with a distinct exit class on timeout.
- **Cardano-node not yet started**: the bootstrap step starts before the node has created its chain DB directory, or before the immutable DB has any chunks. The step waits politely, with its own deadline, distinct from the era-readiness deadline.
- **Concurrent reader/writer on the chain DB**: the cardano-node continuously writes to the chain database while the bootstrap step reads it. The step's read pattern must be safe against this — relying only on the immutable portion of the database, which is append-only by construction.
- **Output volume not empty**: the shared volume already has a complete prior bundle for the same network — short-circuit to exit 0. If it has a partial / interrupted bundle, the step takes responsibility for replacing it; partial overwrites that mix old and new files are not acceptable.
- **Concurrent compose-up calls** (race condition): if two operators run `docker compose up` simultaneously, the bootstrap step must not race against itself in a way that produces a corrupt bundle.
- **Long-running step under fault injection**: under simulator load, the step's elapsed time can stretch. The Amaru services must continue to wait, not time out and start anyway.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST provide a one-shot bootstrap step that, given access to a cardano-node's chain database (live, write-in-progress, or a finished snapshot — the bootstrap step does not care which), produces the complete Amaru bootstrap bundle on a designated shared volume. The mount must be writable for the consensus ImmutableDB validation path, even though the bootstrap step's contract is to consult only immutable chunks.
- **FR-002**: The bootstrap step MUST signal completion through a single, atomic indicator that the operator's container orchestrator can wait on natively, without requiring custom polling logic in the Amaru service.
- **FR-003**: When the bootstrap step succeeds, every required artefact for the Amaru bundle MUST be on the shared volume and complete, including the live ledger store, at least three historical epoch snapshots needed by `amaru run`, and the exact chain-store header matching the ledger tip; when it fails, NO partial Amaru-readable artefact MUST be left behind that could mislead a downstream consumer.
- **FR-004**: Amaru services in the same compose stack MUST be expressible as direct dependents of the bootstrap step using the orchestrator's standard service-dependency vocabulary, without bespoke wait-loops in the Amaru entrypoint.
- **FR-005**: The bootstrap step's failure mode classes MUST be operator-distinguishable. At minimum: chain DB unreachable, chain not yet usable by amaru's consumer, configuration error, internal pipeline tool failure, output filesystem failure — each with its own exit code.
- **FR-006**: The bootstrap step MUST be runnable as a single container image, distributable via a registry the operator already trusts, with all required tooling self-contained — the operator does not pre-install any Cardano binary on the compose host.
- **FR-007**: The bootstrap step MUST NOT depend, transitively or directly, on any patched fork of an upstream Cardano-ecosystem source repository — only on stock upstream releases consumed as binaries or libraries (or small in-repo library consumers per the constitution's Principle II mode (b)).
- **FR-008**: When a prior bootstrap run has produced a complete bundle on the shared volume for the same network, a subsequent compose-up MUST short-circuit to exit 0 immediately, without re-entering any wait or pipeline phase.
- **FR-009**: Multiple Amaru services in the same compose stack MUST be able to depend on a single bootstrap step instance, sharing the same bundle, without coordination between them.
- **FR-010**: The container image carrying the bootstrap step MUST be identifiable by an immutable label tied to the source revision that built it; floating labels (latest, main, dev) MUST NOT be used in production-facing manifests.
- **FR-011**: The bootstrap step MUST decide whether the chain is ready for Amaru to consume by reading the cardano-node's chain database directly, including the era of the immutable tip and the era boundaries of preceding epochs, without coordinating over an out-of-band channel (no marker file from the node, no HTTP callback, no environment-variable hand-off).
- **FR-012**: The bootstrap step's "ready" criterion MUST be: the immutable tip is in the era Amaru consumes (currently Conway), AND the slot two epochs before the immutable tip is at-or-after that same era's first slot. When this is already true (typical mainnet, late preprod, mature antithesis cluster), the bootstrap step proceeds immediately with no wait. When it is not yet true (typical antithesis cold start, freshly-bootstrapped mainnet relay), the bootstrap step polls until it becomes true.

### Key Entities *(include if feature involves data)*

- **Cardano-node chain database (input)**: the operator's cardano-node's working directory, written continuously by the node when it is live, or static if the node is offline. The bootstrap step reads it concurrently and consults only the immutable portion (append-only by construction, safe against the node's concurrent volatile-DB writes). The node-10.7.1 consensus API still opens immutable chunk files with write permissions while validating, so the container mount is read-write even though the bootstrap logic is read-only by behaviour.
- **Era-readiness predicate (derived)**: a property of the chain DB at a given moment — `immutable_tip.era ≥ amaru_consumed_era AND immutable_tip.slot − 2 × epochLength ≥ amaru_consumed_era.firstSlot`. The bootstrap step's wait phase is "block until this predicate holds, with a deadline".
- **Snapshot window (derived)**: the slots at which the bootstrap step produces ledger snapshots. The latest defaults to the immutable tip slot at the moment the era-readiness predicate first holds; the producer also emits snapshots at one and two epoch lengths before that point. By construction these are past the chain's volatility horizon and in the consumed era — no additional safety margin needed.
- **Amaru bootstrap bundle (output)**: the complete set of artefacts an Amaru node needs to start, derived from the cardano-node's chain state at the snapshot window. Includes a populated chain store, a populated ledger store with `live/` plus historical epoch snapshots, a nonces document, and a small set of header documents.
- **Bootstrap step (the worker)**: a one-shot worker that reads the chain DB, waits if necessary for era-readiness, snapshots, and exits. Its lifecycle is "start → check-and-maybe-wait → snapshot → exit (with code)".
- **Shared volume**: the medium between the bootstrap step (writer) and the Amaru services (readers).
- **Service dependency declaration**: the declarative entry, in the operator's compose configuration, that ties an Amaru service's start-up to the bootstrap step's successful completion.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: An operator can start the entire stack — their existing cardano-node, the bootstrap step, and Amaru services — with a single `docker compose up` (or equivalent for the chosen orchestrator). No manual intervention between phases. No follow-up commands. No precomputed chain database.

- **SC-002**: Wall-clock budget from `docker compose up` to amaru-1 reaching running phase:
  - **mainnet / mature chain**: under 10 minutes, dominated by the snapshot pipeline.
  - **antithesis fresh cluster** (Conway-genesis, simulator's typical 100×-150× speedup): under 30 minutes, dominated by the wait for two Conway epochs to forge.

- **SC-003**: When the bootstrap step fails, ZERO Amaru services in the stack start, and the operator can identify the failure by inspecting the bootstrap step's exit code and captured stderr — without needing to read the Amaru services' (which never started). The exit code distinguishes the FR-005 failure classes.

- **SC-004**: After a fault kills an Amaru service mid-run and the orchestrator respawns it, the Amaru service comes back up using the bundle on the shared volume in under 60 seconds wall-clock from the kill, without the bootstrap step re-running.

- **SC-005**: Two consecutive end-to-end runs against the same chain state produce bundles that the same Amaru build accepts identically. Reproducibility holds across the bundle's role as Amaru input, not necessarily byte-for-byte on every internal field; non-determinism is acceptable inside the bundle's storage details only if Amaru's behaviour is invariant.

## Assumptions

- The operator's cardano-node maintains its chain database in a layout that exposes an append-only "immutable" portion the bootstrap step can safely read while the node continues to write. Standard cardano-node releases satisfy this.
- The cardano-node's chain DB volume is mountable read-write into the bootstrap step's container. No special filesystem coordination (locking, snapshotting) is required between the writer (the node) and the reader (the bootstrap step), beyond the orchestrator's standard volume mounting. A read-only mount is rejected by the consensus ImmutableDB opener with `FsInsufficientPermissions`.
- The container orchestrator the operator uses provides a service-dependency primitive equivalent to "this service depends on that one having exited successfully". Any standard compose-style orchestrator does. If the operator's orchestrator does not, the bootstrap-step contract must be re-thought; that is out of scope for this spec.
- The shared volume is provisioned and mounted on both the bootstrap step's container and every Amaru service's container before the stack is brought up. Volume management is the operator's compose configuration concern, not this feature's.
- Amaru's expected bundle layout is treated as a fixed downstream consumer contract — this feature does not modify Amaru. If a future Amaru release changes the bundle layout (or extends the era it consumes), that is a separate Phase 2.5 ticket.
- "The era Amaru consumes" is currently Conway, locked at the SHA pinned in `flake.lock`. If Amaru's main moves to a successor era, FR-012's predicate changes; this is not a spec-rewrite, it is a one-line constant change.
- For the antithesis use case, the simulator's wall-clock-to-cluster-time speedup is high enough that two epochs of cluster time complete within the wait deadline (default 90 minutes). The vendored fixture and antithesis testnet both satisfy this.
- For the mainnet use case, the operator's cardano-node is already past the volatility horizon (k=2160 blocks) within Conway. New mainnet relays catch up to this within hours; the bootstrap step is not the right tool for a *first* compose-up against a freshly-installed cardano-node that has not yet finished its initial sync. That edge is out of scope.
- The operator's network has access to the registry where the bootstrap step's container image is published. This feature does not solve registry-mirror or air-gapped distribution.
- The bootstrap step handles exactly one bundle production per container lifetime. Continuous re-bootstrapping or periodic snapshot refresh is out of scope; if a future operator scenario needs that, it gets its own ticket.
- The orchestrator's restart-policy for Amaru services treats the bootstrap-step dependency as first-time only. Standard compose-style orchestrators behave this way; this assumption is what makes scenario 3 (Amaru kill / respawn) work correctly.
