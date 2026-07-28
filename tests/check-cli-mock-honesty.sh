#!/usr/bin/env bash
set -euo pipefail

# Validate the declared mock surfaces against the real flake-built
# binaries and confirm guard coverage in every audited bats owner.
# Sourced surface arrays are the single source of truth shared with
# the runtime guard in tests/lib/cli-mock-surface.bash.

source "$(dirname "$0")/lib/cli-mock-surface.bash"

fail=0

# --- Amaru: exit 0 from `<path> --help` means accepted ---
for cmd_path in "${CLI_MOCK_ACCEPTED_AMARU[@]}"; do
  # shellcheck disable=SC2086
  if amaru $cmd_path --help >/dev/null 2>&1; then
    printf 'OK: amaru %s accepted by real binary\n' "$cmd_path"
  else
    printf 'FAIL: amaru %s rejected by real binary\n' "$cmd_path" >&2
    fail=1
  fi
done

# --- header-extractor: exit 7 for both valid help and parse errors ---
# Accepted iff output contains the command-specific Usage: line (naming
# the probed subcommand) and no invalid-argument diagnostic.
for cmd_path in "${CLI_MOCK_ACCEPTED_HEADER_EXTRACTOR[@]}"; do
  output="$(header-extractor "$cmd_path" --help 2>&1 || true)"
  if printf '%s\n' "$output" | grep -q "Usage:.*${cmd_path}" \
    && ! printf '%s\n' "$output" | grep -qiE 'invalid|unrecognized|error'; then
    printf 'OK: header-extractor %s accepted by real binary\n' "$cmd_path"
  else
    printf 'FAIL: header-extractor %s not accepted by real binary\n' "$cmd_path" >&2
    fail=1
  fi
done

# --- Known invalid paths must be rejected ---
# shellcheck disable=SC2086
if amaru convert-ledger-state --help >/dev/null 2>&1; then
  printf 'FAIL: amaru convert-ledger-state accepted (expected rejection)\n' >&2
  fail=1
else
  printf 'OK: amaru convert-ledger-state rejected\n'
fi

output="$(header-extractor prev-epoch-tail --help 2>&1 || true)"
if printf '%s\n' "$output" | grep -q 'Usage:.*prev-epoch-tail' \
  && ! printf '%s\n' "$output" | grep -qiE 'invalid|unrecognized|error'; then
  printf 'FAIL: header-extractor prev-epoch-tail accepted (expected rejection)\n' >&2
  fail=1
else
  printf 'OK: header-extractor prev-epoch-tail rejected\n'
fi

# --- Guard coverage: every audited success-capable mock owner ---
for bats_file in \
  tests/test-bootstrap-producer-canonical-cli.bats \
  tests/test-bootstrap-producer-history.bats \
  tests/test-bootstrap-producer-sparse-boundaries.bats \
  tests/test-amaru-relay-bootstrap.bats \
  tests/test-relay-entrypoint.bats \
  tests/test-tool-error.bats; do
  if grep -q 'cli_mock_guard' "$bats_file"; then
    printf 'OK: %s invokes cli_mock_guard\n' "$bats_file"
  else
    printf 'FAIL: %s missing cli_mock_guard\n' "$bats_file" >&2
    fail=1
  fi
done

exit "$fail"
