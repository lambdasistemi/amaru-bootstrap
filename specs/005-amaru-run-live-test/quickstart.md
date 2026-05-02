# Quickstart: Reproducing Issue #34 With the Extended Live Test

This is the day-to-day operator path for the new test. The test runs
outside `Build Gate` because it needs Docker; it is invoked the same
way today's live test is.

## Prerequisites

- Docker daemon reachable from your shell.
- Internet access to pull `ghcr.io/intersectmbo/cardano-node:10.7.1-amd64`
  the first time.
- Either:
  - A locally built bootstrap-producer image (the `live-bootstrap-producer`
    justfile recipe builds and `docker load`s it for you), **or**
  - `BOOTSTRAP_PRODUCER_IMAGE` set to a remote tag you want to verify
    (e.g. the failing image from
    [issue #34](https://github.com/lambdasistemi/amaru-bootstrap/issues/34):
    `ghcr.io/lambdasistemi/amaru-bootstrap-producer:pr-32-ad64e76778b0408ec66f353c7e58c8a1e7d4045f`).

## Run the test (default: locally built producer image)

```sh
just live-bootstrap-producer
```

The recipe (post-extension) brings the flake-pinned `amaru` binary
into the bats environment alongside `db-synthesizer`, `bats`,
`docker-client`, etc.

## Run the test against the issue-#34 failing image

```sh
BOOTSTRAP_PRODUCER_IMAGE=ghcr.io/lambdasistemi/amaru-bootstrap-producer:pr-32-ad64e76778b0408ec66f353c7e58c8a1e7d4045f \
  just live-bootstrap-producer
```

Expected outcome: the on-disk shape assertions still pass; the new
amaru-consume step then fails within ~60 s with one of the four
class-labelled blocks (most likely `vrf` or `rollback` per the issue
report). The bats output names the class and quotes the offending log
lines; you do **not** need to run `docker logs` separately.

## Override the hold window

Useful in CI to give amaru more time to expose late-firing failures,
or in a tight local loop to fail faster:

```sh
BOOTSTRAP_LIVE_AMARU_HOLD_SECONDS=120 just live-bootstrap-producer
BOOTSTRAP_LIVE_AMARU_HOLD_SECONDS=20  just live-bootstrap-producer
```

Default is 60 s.

## What the new step proves (and what it does not)

**Proves**: a bundle emitted by the producer image under test, when
fed to the flake-pinned amaru and peered against the same
cardano-node 10.7.1 container that produced it, does not trigger
`Invalid VRF proof`, `Consensus died`, `HeaderValidationError`, or
`ledger inconsistency` in the first
`BOOTSTRAP_LIVE_AMARU_HOLD_SECONDS` of operation.

**Does not prove**: anything about long-term sync stability, multi-peer
topologies, or *why* a given bundle is rejected. Diagnosis lives in
issue #34's Asks 2 and 3.

## Cleaning up after a failed run

The test's `teardown()` reaps:

- the `amaru run` host process (`SIGTERM` + `wait`),
- both docker containers (`docker rm -f`),
- `$TMP_DIR` (via `docker_rm_worktree` to handle root-owned files
  inside the synthesised ChainDB).

If you ever see a stray `amaru` process after a hard kill of bats,
`pkill amaru` is safe — the test never relies on a long-lived amaru
beyond a single `@test` invocation.

## Where the test fits in the build matrix

| Surface                  | Includes the new step? |
|--------------------------|------------------------|
| `just build-gate`        | No (no Docker)         |
| `nix build .#checks.…`   | No (no Docker)         |
| `just live-bootstrap-producer` | **Yes**          |
| `just ci`                | **Yes** (calls `live-bootstrap-producer` after build-gate) |
| Upstream GitHub Actions  | Inherits whatever `just ci` runs on `runs-on: nixos` self-hosted runners with Docker available. |
