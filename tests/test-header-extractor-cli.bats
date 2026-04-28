#!/usr/bin/env bats

# T006: failing CLI-level coverage for the header-extractor binary.
# Wires
# specs/003-amaru-bootstrap-producer/contracts/bootstrap-producer-cli.md
# (exit-code class rc=7 tool-error: extract) and the JSON shape from
# specs/003-amaru-bootstrap-producer/research.md R-009.
#
# Until T010 replaces app/header-extractor/Main.hs's stub with the
# optparse-applicative dispatch, every assertion below fails — that's
# the TDD red.
#
# Assumes:
#   * `header-extractor` is on PATH (Nix check provides it via
#     nativeBuildInputs)
#   * HEADER_EXTRACTOR_CHAIN_DB points to a synthesised chain DB
#   * HEADER_EXTRACTOR_CONFIG points to the node config dir
#     (the dir that contains config.json + the genesis files)
# The Nix check `header-extractor-cli-bats` in nix/checks.nix wires
# all three. Outside it the suite is skipped.

setup() {
  if ! command -v header-extractor >/dev/null 2>&1; then
    skip "header-extractor not on PATH; run via nix flake check"
  fi
  if [[ -z "${HEADER_EXTRACTOR_CHAIN_DB:-}" \
        || -z "${HEADER_EXTRACTOR_CONFIG:-}" ]]; then
    skip "HEADER_EXTRACTOR_CHAIN_DB / _CONFIG unset; run via nix flake check"
  fi
  TMP_DIR="$(mktemp -d)"
}

teardown() {
  rm -rf "$TMP_DIR"
}

# ── subcommand routing ───────────────────────────────────────────

@test "tip-info subcommand is recognised" {
  run header-extractor tip-info \
      --db "$HEADER_EXTRACTOR_CHAIN_DB" \
      --config "$HEADER_EXTRACTOR_CONFIG/config.json"
  [ "$status" -eq 0 ]
}

@test "list-blocks subcommand is recognised" {
  run header-extractor list-blocks \
      --db "$HEADER_EXTRACTOR_CHAIN_DB" \
      --config "$HEADER_EXTRACTOR_CONFIG/config.json"
  [ "$status" -eq 0 ]
}

@test "get-header subcommand is recognised" {
  run header-extractor list-blocks \
      --db "$HEADER_EXTRACTOR_CHAIN_DB" \
      --config "$HEADER_EXTRACTOR_CONFIG/config.json"
  [ "$status" -eq 0 ]
  first_pair="$(printf '%s\n' "$output" | jq -r '.data[0] | "\(.[0]).\(.[1])"')"
  [[ -n "$first_pair" && "$first_pair" != "null.null" ]]

  run header-extractor get-header "$first_pair" \
      --db "$HEADER_EXTRACTOR_CHAIN_DB" \
      --config "$HEADER_EXTRACTOR_CONFIG/config.json"
  [ "$status" -eq 0 ]
  # Output should be non-empty CBOR bytes; we don't decode, just
  # check the byte count is plausible for a header (>= 64 bytes).
  [ "${#output}" -ge 64 ]
}

# ── flag parsing ─────────────────────────────────────────────────

@test "tip-info rejects missing --db" {
  run header-extractor tip-info --config "$HEADER_EXTRACTOR_CONFIG/config.json"
  [ "$status" -ne 0 ]
}

@test "tip-info rejects missing --config" {
  run header-extractor tip-info --db "$HEADER_EXTRACTOR_CHAIN_DB"
  [ "$status" -ne 0 ]
}

# ── JSON output shape (R-009) ────────────────────────────────────

@test "tip-info stdout is JSON with keys {slot, era, blockHash}" {
  run header-extractor tip-info \
      --db "$HEADER_EXTRACTOR_CHAIN_DB" \
      --config "$HEADER_EXTRACTOR_CONFIG/config.json"
  [ "$status" -eq 0 ]

  slot="$(printf '%s\n' "$output" | jq -r '.slot')"
  era="$(printf '%s\n' "$output" | jq -r '.era')"
  hash="$(printf '%s\n' "$output" | jq -r '.blockHash')"

  [[ "$slot" =~ ^[0-9]+$ ]]
  [ -n "$era" ] && [ "$era" != "null" ]
  [[ "$hash" =~ ^[0-9a-f]+$ ]]
}

@test "tip-info on testnet_42 fixture reports Conway era" {
  run header-extractor tip-info \
      --db "$HEADER_EXTRACTOR_CHAIN_DB" \
      --config "$HEADER_EXTRACTOR_CONFIG/config.json"
  [ "$status" -eq 0 ]
  era="$(printf '%s\n' "$output" | jq -r '.era')"
  [ "$era" = "Conway" ]
}

# ── exit-code mapping (contracts/bootstrap-producer-cli.md) ──────

@test "rc=7 (tool-error: extract) on missing chain DB path" {
  run header-extractor tip-info \
      --db "$TMP_DIR/does-not-exist" \
      --config "$HEADER_EXTRACTOR_CONFIG/config.json"
  [ "$status" -eq 7 ]
}

@test "rc=7 (tool-error: extract) on unparseable config path" {
  printf 'not json\n' >"$TMP_DIR/bad-config.json"
  run header-extractor tip-info \
      --db "$HEADER_EXTRACTOR_CHAIN_DB" \
      --config "$TMP_DIR/bad-config.json"
  [ "$status" -eq 7 ]
}
