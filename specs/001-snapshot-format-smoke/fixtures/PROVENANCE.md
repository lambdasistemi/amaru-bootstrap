# Fixture provenance

## p1-config/

Vendored from
[`pragma-org/amaru/docker/testnet/p1-config`](https://github.com/pragma-org/amaru/tree/d44d84cd9c7a25651c399be96525fe6389e86447/docker/testnet/p1-config).

| | |
|--|--|
| **Source repo** | `pragma-org/amaru` |
| **Source SHA**  | `d44d84cd9c7a25651c399be96525fe6389e86447` |
| **Source path** | `docker/testnet/p1-config` |
| **Vendored at** | 2026-04-27 |
| **Vendored by** | T009 of [`tasks.md`](../tasks.md) |

The SHA matches the `amaru` flake input pinned in
[`flake.lock`](../../../flake.lock); both this fixture and the amaru
binary the smoke test runs come from the same upstream commit.

## Why this bundle

The Phase 0 smoke test needs a self-contained, pre-generated Cardano
testnet bundle: a node config, the genesis files it references, and
credentials for at least one block-producing pool. This bundle is the
minimum viable subset of Arnaud Bailly's testnet:

- one block-producing pool (`p1`) instead of all five (`p1`–`p5`); the
  smoke test's hypothesis only requires one pool to forge blocks
- testnet magic `42`, `k=432`, epoch length `86400` slots — fixed by
  the genesis files; documented in `pragma-org/amaru`'s testnet README
- the keys (`kes.skey`, `vrf.skey`, `cold.skey`, `payment.skey`) are
  devnet-only and already public on GitHub; they are not credentials
  in the security-sensitive sense

## License

The upstream bundle is part of the `pragma-org/amaru` repository,
distributed under Apache-2.0 (matching this repo's [`LICENSE`](../../../LICENSE)).

## Updating

When this bundle is updated:

1. Pick a new SHA from `pragma-org/amaru` main
2. Re-copy the `docker/testnet/p1-config` directory verbatim
3. Update the table above with the new SHA + date
4. Bump the `amaru` input in [`flake.lock`](../../../flake.lock) to the
   same SHA so the binary and the bundle stay aligned
5. Re-run the smoke test against the new bundle to confirm the verdict
