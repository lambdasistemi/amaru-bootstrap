# Research: Bump Amaru to Upstream Main

## R-001 - Freeze execution-time upstream main

**Decision**: Immediately before the implementation edit, capture
`refs/heads/main` from `https://github.com/pragma-org/amaru.git` and treat
that full SHA as the immutable ticket target.

**Rationale**: Issue #68 explicitly says to take the current head at
execution rather than its filing-time example. A raw `git ls-remote` result
provides direct source identity without relying on a GitHub page or human
transcription.

**Alternatives considered**:

- Reuse the filing-time `e706976` example: rejected because upstream may
  advance before implementation.
- Pin a tag or branch name: rejected by Constitution Principle III.

## R-002 - Guard the expected-red premise

**Decision**: Recheck `pragma-org/amaru#1098` immediately before the edit.
If it is merged into the target main revision, stop with a Q-file for the
operator rather than changing the issue's expected-red statement locally.

**Rationale**: The issue makes the open-fix state part of its contract. A
changed upstream premise affects the meaning of the later Antithesis result
and therefore requires ticket-level judgment.

**Alternatives considered**:

- Proceed and silently update the PR language: rejected because it changes
  acceptance rather than implementing it.
- Avoid checking the upstream PR: rejected because the premise is
  temporally unstable and load-bearing.

## R-003 - Update only the Amaru input

**Decision**: Replace the full SHA in `flake.nix`, refresh only the `amaru`
lock input with Nix, and compare lock JSON with `.nodes.amaru` removed to
prove every unrelated node stayed unchanged.

**Rationale**: The source declaration and lock record must agree. Letting
Nix calculate `lastModified` and `narHash` avoids hand-authored fixed-output
metadata, while the structural comparison catches accidental broad lock
updates.

**Alternatives considered**:

- Hand-edit all lock metadata: rejected because generated hashes and
  timestamps should come from Nix.
- Regenerate the entire lock file: rejected because it can move unrelated
  dependencies outside this ticket.

## R-004 - Use the existing real-binary invariant

**Decision**: Keep `cli-mock-honesty` as the command-surface authority.
First seed one rejected accepted-command declaration and prove the check
goes red; restore it, update the pin, and reconcile the allowed CLI test
surface only if the selected real binary proves that necessary.

**Rationale**: Issue #51 already installed a declared-vs-observed invariant
using the flake-built Amaru. A seeded negative control proves the instrument
can fail; using that same check after the pin avoids inventing a second
surface definition.

**Alternatives considered**:

- Scrape top-level help: rejected because compatibility aliases can be
  accepted without appearing there.
- Trust existing green output without a negative control: rejected because
  a check not shown able to fail is not evidence.
- Make mocks permissive to accommodate drift: rejected because that is the
  false-confidence failure the check exists to prevent.

## R-005 - Treat the pin mismatch as the dependency RED

**Decision**: Before editing, run a focused assertion that both dependency
records equal the freshly frozen target and capture its expected nonzero
exit. No permanent exact-SHA test is added.

**Rationale**: The old revision is the ticket's failing state. A permanent
test duplicating the lock's exact SHA would add no independent invariant and
would require editing two truths on every future bump.

**Alternatives considered**:

- Skip RED as a metadata-only change: rejected because the exact-target
  mismatch is executable and observable.
- Add a hard-coded pin test: rejected as redundant with the lock and source
  records it would restate.

## R-006 - Keep the live boundary in acceptance

**Decision**: Run the real-binary honesty check first, then the full
repository gate and Docker live verifier. Require the hosted `Build Gate`
and `Live Bootstrap Producer` checks on the final reviewed commit.

**Rationale**: Unit and build checks cannot prove that the selected Amaru
opens and consumes the bundle produced from a live cardano-node ChainDB.
The existing Docker verifier crosses that exact boundary.

**Alternatives considered**:

- Stop after the Amaru package builds: rejected because it misses both CLI
  wiring and bundle consumption.
- Treat local green as hosted green: rejected because runner and Docker
  state are separate evidence.

## R-007 - Stage deterministic peer snapshots for offline builds

**Decision**: Treat the existing
`cli-green.raw.log`/`CLI_GREEN_EXIT=1` as the RED for an amended single
vertical slice. In `nix/amaru.nix` only, stage the minimal valid
upstream-documented placeholder JSON below
`crates/amaru-node/config/peer-snapshots/{mainnet,preprod,preview}/` and
set `AMARU_SKIP_PEER_SNAPSHOT_FETCH=1`. Stamp the workaround with
`workaround-for=https://github.com/pragma-org/amaru/issues/1102`.

**Rationale**: The selected upstream revision's build script first tries to
derive a snapshot date with `git show`, which is unavailable in a clean Nix
source archive, and then hard-fails when staged snapshots are absent. The
upstream README explicitly documents placeholder snapshots and the skip
environment variable for offline builds. The downstream adaptation keeps
the Amaru source bare and makes the single pin commit buildable.

The placeholders use the documented schema, zero origin point, empty
`bigLedgerPools`, node-to-client version 23, and the network magic values
764824073 (mainnet), 1 (preprod), and 2 (preview).

**Alternatives considered**:

- Split the workaround into a later commit: rejected because the pin commit
  would not build and would therefore not be bisect-safe.
- Patch or fork Amaru: rejected by Constitution Principle I.
- Fetch live peer data during the Nix build: rejected because it violates
  the offline/reproducible build boundary.
- Manufacture a second RED after the ruling: rejected because the existing
  raw failure already proves the amended behavior gap.
