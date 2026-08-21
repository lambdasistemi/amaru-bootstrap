#!/usr/bin/env bash
set -euo pipefail

if (($# == 0)); then
  printf 'usage: lint-bats-negation.sh FILE.bats [...]\n' >&2
  exit 64
fi

status=0
for file in "$@"; do
  if [[ ! -f "$file" ]]; then
    printf '%s: not a regular file\n' "$file" >&2
    status=1
    continue
  fi

  if ! awk '
    function trimmed(value) {
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }

    {
      source[NR] = $0
      inside_test[NR] = in_test
      if ($0 ~ /^[[:space:]]*@test[[:space:]].*\{[[:space:]]*$/) {
        in_test = 1
        inside_test[NR] = 1
      }
      if (in_test && $0 ~ /^}[[:space:]]*(#.*)?$/) {
        inside_test[NR] = 1
        in_test = 0
      }
    }

    END {
      failures = 0
      for (line = 1; line <= NR; line++) {
        statement = trimmed(source[line])
        continued = line > 1 && source[line - 1] ~ /\\[[:space:]]*$/
        if (continued || statement !~ /^![[:space:]]/) {
          continue
        }

        command_end = line
        while (command_end < NR \
          && source[command_end] ~ /\\[[:space:]]*$/) {
          command_end++
        }
        next_line = command_end + 1
        while (next_line <= NR) {
          following = trimmed(source[next_line])
          if (following != "" && following !~ /^#/) {
            break
          }
          next_line++
        }

        if (!inside_test[line] \
          || source[next_line] !~ /^}[[:space:]]*(#.*)?$/) {
          printf "%s:%d: !-prefixed pipeline is not the final test statement\n", \
            FILENAME, line
          failures = 1
        }
      }
      exit failures
    }
  ' "$file"; then
    status=1
  fi
done

if ((status == 0)); then
  printf 'lint-bats-negation: checked=%d result=pass\n' "$#"
fi

exit "$status"
