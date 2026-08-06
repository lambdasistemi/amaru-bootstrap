#!/usr/bin/env bash
# Offline enforcement of the anchored peer-snapshot resolution record (I3).
#
# Factored out of nix/checks.nix so that exactly the same assertions can be
# driven by both the `peer-snapshot-anchor` check (real record, must pass) and
# the `peer-snapshot-anchor-negative-control` check (mutated records, each of
# which must fail). A weakened assertion therefore cannot silently start
# accepting doctored evidence: the negative control turns red instead.
#
# Usage: anchor.sh <record.json> <configs-input-root> <amaru-rev> <configs-rev>
set -euo pipefail

record=${1:?usage: anchor.sh <record> <configs-root> <amaru-rev> <configs-rev>}
configs_root=${2:?missing configs input root}
amaru_rev=${3:?missing amaru rev}
configs_rev=${4:?missing configs rev}

jq -e \
  --arg amaru_rev "$amaru_rev" \
  --arg configs_rev "$configs_rev" \
  '
    type == "object"
    and (keys | sort) == [
      "amaru_committer_date_utc", "amaru_rev", "configs_rev",
      "query_url", "resolved_at_utc", "snapshots"
    ]
    and .amaru_rev == $amaru_rev
    and .configs_rev == $configs_rev
    and (.amaru_rev | test("^[0-9a-f]{40}$"))
    and (.configs_rev | test("^[0-9a-f]{40}$"))
    and (.amaru_committer_date_utc
      | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
    and (.resolved_at_utc
      | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
    and (.query_url | type == "string" and length > 0)
    and (.snapshots | keys | sort) == ["mainnet", "preprod", "preview"]
    and ([.snapshots[].sha256
      | test("^[0-9a-f]{64}$")] | all)
  ' "$record" >/dev/null || {
  echo "peer-snapshot anchor failed: record schema or locked revisions disagree" >&2
  exit 1
}

for network in mainnet preprod preview; do
  expected=$(jq -r --arg network "$network" \
    '.snapshots[$network].sha256' "$record")
  snapshot="$configs_root/network/$network/cardano-node/peer-snapshot.json"
  if [ ! -f "$snapshot" ]; then
    echo "peer-snapshot anchor failed: $network input file missing: $snapshot" >&2
    exit 1
  fi
  actual=$(sha256sum "$snapshot" | cut -d' ' -f1)
  if [ "$actual" != "$expected" ]; then
    echo "peer-snapshot anchor failed: $network input sha256 $actual != $expected" >&2
    exit 1
  fi
  echo "peer-snapshot anchor passed: $network sha256=$actual"
done
