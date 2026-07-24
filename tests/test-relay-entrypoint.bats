#!/usr/bin/env bats

# Verify the relay entrypoint uses canonical `amaru node run` and
# requires the 3 consensus-critical AMARU_GLOBAL_* env vars.
# Per lambdasistemi/amaru-bootstrap#48 slice 3.

setup() {
  TMP_DIR="$(mktemp -d)"
  RELAY_SCRIPT="$BATS_TEST_DIRNAME/../scripts/relay-entrypoint.sh"

  # Create a mock bundle
  mkdir -p "$TMP_DIR/bundle/testnet_42/ledger.testnet_42.db"
  mkdir -p "$TMP_DIR/bundle/testnet_42/chain.testnet_42.db"
  echo '{"eras":[]}' > "$TMP_DIR/bundle/testnet_42/era-history.json"

  # Create state dir
  mkdir -p "$TMP_DIR/state"

  # Mock amaru
  MOCK_BIN="$TMP_DIR/mock-bin"
  mkdir -p "$MOCK_BIN"
  cat >"$MOCK_BIN/amaru" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
cmd="$1"; shift
case "$cmd" in
  node)
    sub="$1"; shift
    case "$sub" in
      run)
        echo "AMARU_NODE_RUN_CALLED"
        # Verify --era-history is passed
        found_era=false
        for arg in "$@"; do
          [[ "$arg" == "--era-history" ]] && found_era=true
        done
        $found_era || { echo "MISSING --era-history" >&2; exit 1; }
        exit 0
        ;;
      *) echo "unexpected: node $sub" >&2; exit 1 ;;
    esac
    ;;
  run)
    echo "REJECTED: legacy 'amaru run' (use: amaru node run)" >&2
    exit 1
    ;;
  *) echo "unexpected: $cmd" >&2; exit 1 ;;
esac
SHIM
  chmod +x "$MOCK_BIN/amaru"
  export PATH="$MOCK_BIN:$PATH"
}

teardown() {
  rm -rf "$TMP_DIR"
}

@test "relay entrypoint uses amaru node run (not legacy amaru run)" {
  export AMARU_GLOBAL_CONSENSUS_SECURITY_PARAM=20
  export AMARU_GLOBAL_ACTIVE_SLOT_COEFF_INVERSE=5
  export AMARU_GLOBAL_EPOCH_LENGTH_SCALE_FACTOR=4

  run bash "$RELAY_SCRIPT" testnet_42 "$TMP_DIR/bundle" "$TMP_DIR/state" "0.0.0.0:3001" "relay1:3001"

  [ "$status" -eq 0 ]
  [[ "$output" == *"AMARU_NODE_RUN_CALLED"* ]]
}

@test "relay entrypoint fails without AMARU_GLOBAL_CONSENSUS_SECURITY_PARAM" {
  unset AMARU_GLOBAL_CONSENSUS_SECURITY_PARAM
  export AMARU_GLOBAL_ACTIVE_SLOT_COEFF_INVERSE=5
  export AMARU_GLOBAL_EPOCH_LENGTH_SCALE_FACTOR=4

  run bash "$RELAY_SCRIPT" testnet_42 "$TMP_DIR/bundle" "$TMP_DIR/state" "0.0.0.0:3001" "relay1:3001"

  [ "$status" -ne 0 ]
}

@test "relay entrypoint fails without AMARU_GLOBAL_EPOCH_LENGTH_SCALE_FACTOR" {
  export AMARU_GLOBAL_CONSENSUS_SECURITY_PARAM=20
  export AMARU_GLOBAL_ACTIVE_SLOT_COEFF_INVERSE=5
  unset AMARU_GLOBAL_EPOCH_LENGTH_SCALE_FACTOR

  run bash "$RELAY_SCRIPT" testnet_42 "$TMP_DIR/bundle" "$TMP_DIR/state" "0.0.0.0:3001" "relay1:3001"

  [ "$status" -ne 0 ]
}
