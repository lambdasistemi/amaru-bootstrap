#!/usr/bin/env bats

load 'lib/bootstrap-helpers'

setup() {
  TMP_DIR="$(mktemp -d)"
  mkdir -p "$TMP_DIR/bin" "$TMP_DIR/chain-db/immutable" \
           "$TMP_DIR/config" "$TMP_DIR/bundle"
  : >"$TMP_DIR/chain-db/immutable/00000.chunk"

  printf '{"TestConwayHardForkAtEpoch":0}\n' >"$TMP_DIR/config/config.json"
  printf '{"epochLength":100}\n' >"$TMP_DIR/config/shelley-genesis.json"

  export TMP_DIR
  export PATH="$TMP_DIR/bin:$PATH"
  export AMARU_NETWORK=testnet_42
  export AMARU_CLUSTER_READY_DEADLINE_SECONDS=1
  export AMARU_WAIT_DEADLINE_SECONDS=1
  export AMARU_POLL_INTERVAL_SECONDS=1
  export CLI_MOCK_SURFACE_LIB="$BATS_TEST_DIRNAME/lib/cli-mock-surface.bash"

  # Sparse chain: the last block of completed epochs 1/2/3 lands at slots
  # 188/287/397 (epochLength 100, tip in epoch 4). Hashes are hex so the
  # producer's <slot>.<hash> snapshot-dir validation accepts them.
  hexhash() { printf '%064x' "$1"; }
  cat >"$TMP_DIR/list-blocks.json" <<EOF
{"data":[[88,"$(hexhash 88)"],[188,"$(hexhash 188)"],[287,"$(hexhash 287)"],[397,"$(hexhash 397)"],[401,"$(hexhash 401)"]]}
EOF

  {
    printf '#!%s\n' "$BASH"
    cat <<'EOF'
set -euo pipefail
source "$CLI_MOCK_SURFACE_LIB"
cli_mock_guard header-extractor "$@"
case "$1" in
  tip-info)
    printf '{"slot":405,"era":"Conway"}\n'
    ;;
  list-blocks)
    cat "$TMP_DIR/list-blocks.json"
    ;;
  *)
    printf 'unexpected header-extractor command: %s\n' "$*" >&2
    exit 64
    ;;
esac
EOF
  } >"$TMP_DIR/bin/header-extractor"

  # amaru stub, canonical bare-main CLI: `snapshot create` materializes
  # one node-snapshot dir per --snapshot point (Koios/Mithril/db-analyser
  # all bypassed via the flags); `node bootstrap` produces the ledger +
  # chain DBs. The legacy aliases are rejected so this suite keeps
  # guarding the native-CLI migration.
  {
    printf '#!%s\n' "$BASH"
    cat <<'EOF'
set -euo pipefail
source "$CLI_MOCK_SURFACE_LIB"
cli_mock_guard amaru "$@"
cmd="$1"; shift
case "$cmd" in
  snapshot)
    sub="$1"; shift
    [ "$sub" = create ] || {
      printf 'unexpected amaru command: snapshot %s\n' "$sub" >&2
      exit 64
    }
    snapdir=""; points=()
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --snapshot) points+=("$2"); shift 2 ;;
        --snapshot-dir) snapdir="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    mkdir -p "$snapdir"
    for p in "${points[@]}"; do
      point="${p%%::*}"
      d="$snapdir/$point"
      mkdir -p "$d/tables"
      : >"$d/state"
      : >"$d/tables/tvar"
      printf '[]\n' >"$d/bootstrap.headers.json"
    done
    ;;
  node)
    sub="$1"; shift
    [ "$sub" = bootstrap ] || {
      printf 'unexpected amaru command: node %s\n' "$sub" >&2
      exit 64
    }
    ledger=""; chain=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --ledger-dir) ledger="$2"; shift 2 ;;
        --chain-dir) chain="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    mkdir -p "$ledger/live" "$ledger/1" "$ledger/2" "$ledger/3" "$chain"
    ;;
  create-snapshots|bootstrap)
    printf 'legacy alias rejected: amaru %s (use the canonical native CLI)\n' \
           "$cmd" >&2
    exit 64
    ;;
  *)
    printf 'unexpected amaru command: %s\n' "$cmd" >&2
    exit 64
    ;;
esac
EOF
  } >"$TMP_DIR/bin/amaru"

  chmod +x "$TMP_DIR/bin/header-extractor" "$TMP_DIR/bin/amaru"
}

teardown() {
  rm -rf "$TMP_DIR"
}

@test "sparse epoch boundaries select actual blocks from three distinct completed epochs" {
  run "$BOOTSTRAP_PRODUCER_SCRIPT" \
      "$TMP_DIR/chain-db" \
      "$TMP_DIR/config" \
      "$TMP_DIR/bundle" \
      testnet_42

  [ "$status" -eq 0 ]
  slots="$(
    find "$TMP_DIR/bundle/testnet_42/snapshots/testnet_42" \
      -mindepth 1 -maxdepth 1 -type d -printf '%f\n' \
      | cut -d. -f1 | sort -n | tr '\n' ' '
  )"
  [ "$slots" = "188 287 397 " ]
}
