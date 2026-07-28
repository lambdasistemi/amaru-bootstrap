#!/usr/bin/env bash
# Shared declared CLI mock surfaces and fail-closed guard.
# Sourced by success-capable test doubles and the real-binary checker.
# The arrays below are the single source of truth for which command
# paths a mock may accept; the Nix honesty check validates them
# against the real flake-built binaries.

# Accepted command paths per binary.
CLI_MOCK_ACCEPTED_AMARU=("snapshot create" "node bootstrap" "node run" "run")

# Helpers exempt from the reachability audit. Each entry is a function
# name declared under tests/lib/. Adding an entry is a reviewable diff.
# A stale entry (matching no declaration) or a redundant entry (the
# helper already has a call site) is a hard failure in the checker.
HELPER_REACHABILITY_EXEMPT=()

# cli_mock_guard <binary> [args...]
# Extracts the command path from the leading positional arguments and
# exits 1 if the path is not in the declared accepted surface.
# Invoke before any success-producing logic in a mock.
cli_mock_guard() {
  local binary="$1"
  shift
  local cmd_path
  case "$binary" in
    amaru)
      case "${1:-}" in
        snapshot | node) cmd_path="${1:-} ${2:-}" ;;
        *) cmd_path="${1:-}" ;;
      esac
      ;;
    *)
      printf 'cli_mock_guard: unknown binary: %s\n' "$binary" >&2
      exit 1
      ;;
  esac

  local -a surface=()
  case "$binary" in
    amaru) surface=("${CLI_MOCK_ACCEPTED_AMARU[@]}") ;;
  esac

  local accepted
  for accepted in "${surface[@]}"; do
    [[ "$cmd_path" == "$accepted" ]] && return 0
  done

  printf '%s mock: rejected command path: %s\n' "$binary" "$cmd_path" >&2
  exit 1
}
