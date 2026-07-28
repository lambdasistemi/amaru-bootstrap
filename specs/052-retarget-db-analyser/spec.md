# Feature Specification: Retarget Producer at db-analyser

**Feature Branch**: `052-retarget-db-analyser`
**Created**: 2026-07-28
**Status**: Ready for planning
**Input**: GitHub issue
[`lambdasistemi/amaru-bootstrap#52`](https://github.com/lambdasistemi/amaru-bootstrap/issues/52)
and its
[measured replacement assessment](https://github.com/lambdasistemi/amaru-bootstrap/blob/explore/header-extractor-via-db-analyser/.llm/header-extractor-vs-db-analyser.md)

## User Scenarios & Testing

### User Story 1 - Produce the Same Bundle with Stock Tools (Priority: P1)

As an operator, I run the bootstrap producer against a cardano-node chain DB
and receive the same usable Amaru bundle without an in-repository executable
between the producer and the pinned upstream chain database tooling.

**Why this priority**: Amaru consumes only six chain points from the producer:
the last block of each of three completed epochs and each block's parent. The
stock tool already exposes those points, so retaining a purpose-built
executable adds maintenance and image surface without adding capability.

**Independent Test**: Run the producer on the synthesized `testnet_42` chain
database before and after the refactor, assert all six extracted points against
frozen expected values, compare the resulting bundle contract, and open the
bundle with the pinned Amaru runtime.

**Acceptance Scenarios**:

1. **Given** a chain with at least three complete usable epochs, **when** the
   producer runs, **then** it selects exactly the three epoch-tail points and
   their three immediate parents and produces a complete bundle.
2. **Given** an absent or empty chain database, **when** the readiness poll
   runs, **then** origin is treated as not ready even though the upstream tool
   reports success.
3. **Given** upstream output that no longer matches the pinned format, **when**
   the real synthesized-chain check runs, **then** extraction fails rather
   than accepting zero points.
4. **Given** the canonical fixture and unchanged dependency pins, **when** the
   completed producer is compared with the pre-change producer, **then** the
   bundle's deterministic contract is byte-identical and its live verifier
   passes.

---

### User Story 2 - Remove the Redundant Tool Surface (Priority: P2)

As a maintainer, I build, inspect, and document the repository without finding
an executable, package, application, check, test double, or image layer for the
retired `header-extractor`.

**Why this priority**: Removing the live tool surface satisfies the stock-tools
constitution and prevents users and maintainers from depending on an obsolete
interface.

**Independent Test**: Enumerate the live source, flake, CI, image, test, agent,
and current documentation surfaces and confirm that none exposes or advertises
the retired tool while historical records remain unchanged.

**Acceptance Scenarios**:

1. **Given** the completed branch, **when** flake packages, applications,
   checks, CI jobs, Just recipes, and image contents are enumerated, **then**
   none exposes `header-extractor`.
2. **Given** current operator, developer, and agent guidance, **when** exact
   references are audited, **then** none advertises the retired tool.
3. **Given** historical specifications, project history, and the constitution,
   **when** the removal lands, **then** those records remain unchanged.

### Edge Cases

- The pinned upstream tool reports exit code zero and `Point Origin` for an
  absent or empty database; readiness must not confuse that state with a real
  tip.
- A chain may have a tip in the fourth or later epoch but no block in one of
  the three required completed epochs; that chain remains not ready.
- The upstream per-block output is debug `Show` text rather than a stable
  machine interface. A parse that yields fewer or more than six required
  points must fail the real-chain check.
- Epoch-boundary slots are usually empty. Extraction must not probe backward
  from exact epoch boundaries or use bounded anchoring.
- A read-only chain database remains a classified producer tool failure with
  an actionable mount diagnostic.
- `NodeConfig` is retained as directed even though sibling issue #50 removed
  its former ledger-state-emitter consumer.
- `specs/00*`, `docs/history/**`, the constitution, the Amaru pin, other
  worktrees, and generated `site/**` output are excluded from this change.

## Requirements

### Functional Requirements

- **FR-001**: The readiness poll MUST obtain the immutable tip through the
  cheapest pinned upstream query: no analysis mode and minimum block
  validation.
- **FR-002**: `Point Origin` MUST be recognized explicitly and MUST leave the
  producer in the not-ready state.
- **FR-003**: Readiness MUST require a tip epoch of at least three, one usable
  tail point in each of the three immediately completed epochs, and the oldest
  selected point at or after the configured Conway start slot.
- **FR-004**: Point extraction MUST make one forward pass and MUST materialize
  exactly six `(slot, hash)` values: three consecutive completed epoch tails
  and their immediate parents.
- **FR-005**: The producer MUST write `targets.json` directly and MUST no
  longer create or consume `preflight-blocks.json`.
- **FR-006**: Extraction MUST fail closed when the pinned upstream output
  format yields an incomplete six-point set.
- **FR-007**: Chain-database tool failures MUST remain producer exit class 7,
  including the existing actionable diagnostic for a read-only mount.
- **FR-008**: A Nix check MUST run the real extractor against a synthesized
  chain database, assert all six exact points, and include a negative control
  proving that zero parsed lines fail.
- **FR-009**: The producer's synthesized fixture bundle MUST preserve its
  deterministic byte contract, and the live cardano-node verifier MUST pass.
- **FR-010**: The project MUST remove the `header-extractor` executable,
  implementation module, CLI wrapper, Haskell spec suite, CLI bats suite,
  flake package/app/check surfaces, CI jobs, Just entries, test doubles, and
  producer image input.
- **FR-011**: The `NodeConfig` type MUST remain available outside the deleted
  `HeaderExtractor` module.
- **FR-012**: Current-facing README, architecture, producer, index, agent, and
  repository-guide documentation MUST describe the stock-tool flow and MUST
  not advertise the removed executable.
- **FR-013**: Historical specifications and documentation, the constitution,
  generated `site/**`, dependency pins, and unrelated sibling behavior MUST
  remain unchanged.

## Success Criteria

### Measurable Outcomes

- **SC-001**: The synthesized-chain check asserts exactly six expected
  `(slot, hash)` pairs and its zero-line negative control exits nonzero.
- **SC-002**: The completed producer creates zero
  `preflight-blocks.json` files and one valid `targets.json` containing three
  target records with their three parents.
- **SC-003**: An absent or empty chain database produces zero false-ready
  outcomes during the readiness poll.
- **SC-004**: The deterministic `testnet_42` bundle comparison reports zero
  byte differences outside pre-existing nondeterministic RocksDB physical
  files.
- **SC-005**: Flake evaluation, CI definitions, Just recipes, and the producer
  image expose zero `header-extractor` entries or executable paths.
- **SC-006**: The live-surface exact-name audit reports zero matches outside
  this ticket's process documents and approved historical/generated
  exclusions.
- **SC-007**: `nix flake check`, `just build-gate`, and
  `just live-bootstrap-producer` each exit zero.

## Assumptions

- Issues #50 and #51 are merged into the branch baseline.
- The public measured assessment is the frozen research basis; this ticket
  does not repeat its performance experiment or reconsider rejected bounded
  anchoring.
- The repository remains pinned to the same cardano-node and
  `ouroboros-consensus` revisions.
- Upstream Amaru issue #8 may eventually remove this extraction entirely, so
  this ticket intentionally keeps the replacement small.
- The user's instruction to execute issue #52 supplies the constitution's
  required explicit approval for the named deletion surface.
