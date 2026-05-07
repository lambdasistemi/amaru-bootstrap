#!/usr/bin/env bats

RELAY_BOOTSTRAP_SCRIPT="${BATS_TEST_DIRNAME}/../scripts/amaru-relay-bootstrap.sh"

setup() {
  export TMP_DIR
  TMP_DIR="$(mktemp -d)"
  mkdir -p "$TMP_DIR/bin" "$TMP_DIR/final" "$TMP_DIR/live" \
           "$TMP_DIR/config" "$TMP_DIR/runtime" "$TMP_DIR/startup"

  export RELAY_NAME=amaru-relay-1
  export AMARU_PEER=p1:3001
  export AMARU_NETWORK=testnet_42
  export AMARU_RELAY_FINAL_DIR="$TMP_DIR/final"
  export AMARU_RELAY_LIVE_DIR="$TMP_DIR/live"
  export AMARU_RELAY_CONFIG_DIR="$TMP_DIR/config"
  export AMARU_RELAY_RUNTIME_DIR="$TMP_DIR/runtime"
  export AMARU_RELAY_STARTUP_DIR="$TMP_DIR/startup"
  export AMARU_BOOTSTRAP_RETRY_SECONDS=0
  export BOOTSTRAP_PRODUCER_BIN="$TMP_DIR/bin/bootstrap-producer"
  export AMARU_BIN="$TMP_DIR/bin/amaru"
  export FAKE_AMARU_ARGS="$TMP_DIR/amaru.args"

  {
    printf '#!%s\n' "$BASH"
    cat <<'EOF'
printf '%s\n' "$@" >"$FAKE_AMARU_ARGS"
EOF
  } >"$AMARU_BIN"
  chmod +x "$AMARU_BIN"
}

teardown() {
  rm -rf "$TMP_DIR"
}

make_complete_final_bundle() {
  mkdir -p "$TMP_DIR/final/chain.testnet_42.db" \
           "$TMP_DIR/final/ledger.testnet_42.db/live" \
           "$TMP_DIR/final/ledger.testnet_42.db/1" \
           "$TMP_DIR/final/ledger.testnet_42.db/2" \
           "$TMP_DIR/final/ledger.testnet_42.db/3"
  : >"$TMP_DIR/final/chain.testnet_42.db/CURRENT"
  : >"$TMP_DIR/final/ledger.testnet_42.db/live/CURRENT"
  : >"$TMP_DIR/final/ledger.testnet_42.db/1/CURRENT"
  : >"$TMP_DIR/final/ledger.testnet_42.db/2/CURRENT"
  : >"$TMP_DIR/final/ledger.testnet_42.db/3/CURRENT"
  printf '{}\n' >"$TMP_DIR/final/nonces.json"
  : >"$TMP_DIR/final/.bootstrap-complete"
}

make_live_mount() {
  mkdir -p "$TMP_DIR/live/immutable" "$TMP_DIR/live/ledger" "$TMP_DIR/live/volatile"
  printf '42\n' >"$TMP_DIR/live/protocolMagicId"
  : >"$TMP_DIR/live/lock"
}

@test "existing numeric stable snapshots skip producer and exec amaru" {
  make_complete_final_bundle
  {
    printf '#!%s\n' "$BASH"
    cat <<'EOF'
echo called >"$TMP_DIR/producer.called"
exit 66
EOF
  } >"$BOOTSTRAP_PRODUCER_BIN"
  chmod +x "$BOOTSTRAP_PRODUCER_BIN"

  run "$RELAY_BOOTSTRAP_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"bundle already complete at $TMP_DIR/final, skipping bootstrap loop"* ]]
  [[ "$output" == *"bundle ready at $TMP_DIR/final, exec'ing amaru run"* ]]
  [ ! -e "$TMP_DIR/producer.called" ]
  args="$(<"$FAKE_AMARU_ARGS")"
  [[ "$args" == *"--ledger-dir"* ]]
  [[ "$args" == *"$TMP_DIR/final/ledger.testnet_42.db"* ]]
}

@test "promoted 1/2/3/live bundle is considered complete on next loop" {
  make_live_mount
  {
    printf '#!%s\n' "$BASH"
    cat <<'EOF'
count_file="$TMP_DIR/producer.count"
count="$(cat "$count_file" 2>/dev/null || printf '0')"
count=$((count + 1))
printf '%s\n' "$count" >"$count_file"
if [ "$count" -gt 1 ]; then
  exit 66
fi

out="$3"
network="$4"
bundle="$out/$network"
mkdir -p "$bundle/chain.$network.db" \
         "$bundle/ledger.$network.db/live" \
         "$bundle/ledger.$network.db/1" \
         "$bundle/ledger.$network.db/2" \
         "$bundle/ledger.$network.db/3"
: >"$bundle/chain.$network.db/CURRENT"
: >"$bundle/ledger.$network.db/live/CURRENT"
: >"$bundle/ledger.$network.db/1/CURRENT"
: >"$bundle/ledger.$network.db/2/CURRENT"
: >"$bundle/ledger.$network.db/3/CURRENT"
printf '{}\n' >"$bundle/nonces.json"
EOF
  } >"$BOOTSTRAP_PRODUCER_BIN"
  chmod +x "$BOOTSTRAP_PRODUCER_BIN"

  run "$RELAY_BOOTSTRAP_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"bootstrap attempt #1: committed bundle to $TMP_DIR/final"* ]]
  [[ "$output" == *"bundle already complete at $TMP_DIR/final, skipping bootstrap loop"* ]]
  [ "$(cat "$TMP_DIR/producer.count")" -eq 1 ]
  [ -f "$TMP_DIR/final/.bootstrap-complete" ]
  [ -f "$TMP_DIR/final/ledger.testnet_42.db/1/CURRENT" ]
  [ -f "$TMP_DIR/final/ledger.testnet_42.db/2/CURRENT" ]
  [ -f "$TMP_DIR/final/ledger.testnet_42.db/3/CURRENT" ]
  [ ! -e "$TMP_DIR/final/ledger.testnet_42.db/0/CURRENT" ]
}

@test "promoted 1/2/live bundle is not complete enough to exec amaru" {
  make_live_mount
  {
    printf '#!%s\n' "$BASH"
    cat <<'EOF'
count_file="$TMP_DIR/producer.count"
count="$(cat "$count_file" 2>/dev/null || printf '0')"
count=$((count + 1))
printf '%s\n' "$count" >"$count_file"
if [ "$count" -gt 1 ]; then
  exit 66
fi

out="$3"
network="$4"
bundle="$out/$network"
mkdir -p "$bundle/chain.$network.db" \
         "$bundle/ledger.$network.db/live" \
         "$bundle/ledger.$network.db/1" \
         "$bundle/ledger.$network.db/2"
: >"$bundle/chain.$network.db/CURRENT"
: >"$bundle/ledger.$network.db/live/CURRENT"
: >"$bundle/ledger.$network.db/1/CURRENT"
: >"$bundle/ledger.$network.db/2/CURRENT"
printf '{}\n' >"$bundle/nonces.json"
EOF
  } >"$BOOTSTRAP_PRODUCER_BIN"
  chmod +x "$BOOTSTRAP_PRODUCER_BIN"

  run "$RELAY_BOOTSTRAP_SCRIPT"

  [ "$status" -eq 66 ]
  [[ "$output" == *"bootstrap attempt #1: committed bundle to $TMP_DIR/final"* ]]
  [[ "$output" != *"bundle ready at $TMP_DIR/final, exec'ing amaru run"* ]]
  [ "$(cat "$TMP_DIR/producer.count")" -eq 2 ]
  [ ! -e "$FAKE_AMARU_ARGS" ]
}
