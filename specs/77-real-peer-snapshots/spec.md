# Spec — real pinned peer-snapshot contents in the offline amaru build

Issue: lambdasistemi/amaru-bootstrap#77
Branch: `feat/77-real-peer-snapshots`

## Problem

`nix/amaru.nix` stages empty schema-conformant placeholder peer-snapshots
(`bigLedgerPools = []`) under `AMARU_SKIP_PEER_SNAPSHOT_FETCH=1`
(workaround-for pragma-org/amaru#1102). The shipped amaru binary therefore
embeds no real big-ledger peers.

## User stories

- As the antithesis test operator, I want the offline-built amaru binary to
  embed the same peer-snapshot bytes an online upstream build would embed for
  the pinned amaru rev, so test-network behavior matches upstream.
- As the daily-bump automation author (epic #205), I want a documented,
  mechanical procedure to re-resolve the configurations rev on each amaru
  bump, so the pin never drifts silently.

## Requirements

- R1. The amaru package embeds, for each network in
  `amaru_kernel::PEER_SNAPSHOT_NETWORKS` (mainnet, preprod, preview), the
  exact `network/<net>/cardano-node/peer-snapshot.json` bytes from
  `cardano-foundation/cardano-configurations` at the rev selected by the
  upstream resolution rule (research.md R-RULE) for the pinned amaru rev.
- R2. `cardano-configurations` is consumed as a SHA-pinned, non-flake input
  (constitution Principle III); staging is additive only — no upstream source
  patched, forked, or vendored (Principle I).
- R3. The build embeds the resolved configs-rev provenance: a staged
  `CONFIGS_COMMIT_CACHE` containing `sha: <pinned configs rev>` so the
  generated `CONFIGS_COMMIT` constant is `Some(<rev>)`, not `None`.
- R4. The empty-placeholder path survives only as an explicitly selected dev
  fallback (a distinct nix attribute/argument named in plan.md); the default
  `amaru` package never silently falls back to placeholders.
- R5. The derived resolution rule is documented in the repo (docs page), with
  the re-resolution procedure for each amaru bump (epic #205 consumption),
  including the future-dated-pin and backdated-commit edge cases and why
  enforcement is anchored (v3).
- R6. A committed, machine-readable resolution record anchors the pin: amaru
  rev + committer date, resolved configs rev, resolution timestamp, query
  provenance, and per-network snapshot sha256. It is updated only at
  deliberate pin bumps.
- R7. Enforcement parity (audit advisories A1/A2): the negative-control and
  anchored checks run in remote CI's Build Gate list, and the repo shellcheck
  check covers every production script added by this ticket.

## Invariants (each proven able to fail)

- I1 (presence): the default amaru build FAILS if any per-network staged file
  is missing. Negative control required.
- I2 (schema): the default amaru build FAILS if any staged file violates
  `peer-snapshot.schema.json` (from the pinned amaru source) or carries the
  wrong `NetworkMagic` for its network (mainnet 764824073, preprod 1,
  preview 2), or has empty `bigLedgerPools`. Negative control required.
- I3 (anchored equivalence, v3 — operator ruling 2026-08-06): CI and the
  build compare ONLY against recorded resolution evidence (R6) captured at
  bump time — never against the live GitHub API. RED if the recorded
  amaru rev, configs rev, or any per-network snapshot sha256 disagrees with
  flake.lock / the staged input bytes. Negative control: a tampered staged
  file (or doctored record) is RED. Rationale: a FUTURE-dated amaru pin
  makes the live rule resolve nondeterministically until wall-clock passes,
  and a BACKDATED configurations commit can retroactively change what the
  live rule selects; both edges can bite only at the resolution event (pin
  bump), so re-resolution happens solely there.
- I3b (bump-time re-resolution): an executable tool re-derives the rule
  online and writes/refreshes the R6 record, logging the resolved rev and
  query evidence; drift then surfaces as a reviewable diff at the bump.
  Proven RED against a doctored lock/rev.
- I4 (no silent placeholder): the default package output embeds non-empty
  `bigLedgerPools` for every network; a build embedding a placeholder is RED.

## Rejection behavior

- Missing/malformed staged file → loud nix build failure naming the network
  and the reason (I1/I2).
- Equivalence drift (amaru bumped without re-resolving configs) → I3 check
  exits non-zero with both revs printed.

## Observable success

- `nix build .#checks.x86_64-linux.amaru` green with real contents embedded.
- I3 anchored checks green offline for the current pins; I3b bump tool
  green in check-only mode against the current record.
- Negative controls demonstrably red (evidence recorded in ticket runtime
  root).
- Docs page published describing rule + bump procedure.
