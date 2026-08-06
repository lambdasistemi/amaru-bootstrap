# Peer-snapshot pinning

The default Amaru build embeds real peer snapshots from the SHA-pinned
`cardano-foundation/cardano-configurations` flake input. Builds and CI never
query GitHub: they compare the pinned inputs with the committed evidence in
`nix/peer-snapshots/resolution.json`.

## Resolution rule

At Amaru bump time, the repository resolves the configuration revision by:

1. reading the committer date of the pinned Amaru commit from
   `nodes.amaru.locked.lastModified` in `flake.lock`;
2. asking GitHub for the newest `cardano-configurations` commit whose
   committer date is at or before that instant; and
3. fetching the mainnet, preprod, and preview peer snapshots from that exact
   revision and recording their SHA-256 hashes.

The evidence record captures the Amaru revision and committer time, the
resolved configurations revision, the query URL and resolution time, and all
three content hashes. The current configurations resolution is
`4a9b69103507b124679fcb185eeabd4dc15e9c75`.

## Why enforcement is anchored

A live query is not a reproducible CI oracle. If an Amaru pin has a
future-dated committer timestamp, more configurations commits can become
eligible as wall-clock time catches up. A newly published, backdated
configurations commit can also retroactively change the newest commit before
an already fixed cutoff. The same pins could therefore pass today and fail
tomorrow without any repository change.

Those edges matter only when a pin is deliberately resolved. The bump-time
tool performs the live query once and records the result for review. From
then on, `peer-snapshot-anchor` and the Amaru build enforce the record entirely
offline against both flake revisions and exact input bytes. The negative
control proves a staged-byte mismatch makes the build fail.

## Amaru bump procedure (epic #205)

For every Amaru bump:

1. bump the SHA-pinned `amaru` input and refresh its lock entry;
2. run `just resolve-peer-snapshots --write` to re-run the live rule and
   refresh the proposed evidence (an interim mismatch is expected if the
   configurations input still points at the previous resolution);
3. update the SHA-pinned `cardano-configurations` input to the revision shown
   in `nix/peer-snapshots/resolution.json` and refresh its lock entry;
4. review the complete `resolution.json` diff, including all three hashes;
5. rerun `just resolve-peer-snapshots --write`, then `just build-gate`.

The default tool mode is check-only: it prints the proposed record and a diff,
then exits non-zero on any drift. `--write` is the only mode that updates the
record. `GITHUB_TOKEN` or `GH_TOKEN` may be set for authenticated API limits;
`FLAKE_LOCK` may point at a temporary lock file when checking a proposed bump.
The tool is intentionally absent from every CI workflow.
