# Quickstart: Verify Build Gate CLI Mock Honesty Wiring

Run every command from `/code/amaru-bootstrap-70`. Preserve raw output under
`/tmp/epic-55/amaru-bootstrap-70/logs/`. Set a ticket-specific Nix evaluation
cache when commands may overlap another worker:

```bash
export XDG_CACHE_HOME=/tmp/epic-55/amaru-bootstrap-70/nix-cache
```

## 1. Structural alignment

```bash
test "$(grep -Fc '.#checks.x86_64-linux.cli-mock-honesty' \
  .github/workflows/ci.yml)" -eq 1
test "$(grep -Fc '.#checks.x86_64-linux.cli-mock-honesty' justfile)" -eq 1
```

Both commands must exit 0.

## 2. Exact closure reachability

```bash
mapfile -t hosted_targets < <(
  awk '
    /- name: Build all flake checks/ { in_step=1; next }
    in_step && /^[[:space:]]+- name:/ { exit }
    in_step { print }
  ' .github/workflows/ci.yml \
    | grep -oE '\.#checks\.x86_64-linux\.[a-z0-9-]+'
)

mapfile -t local_targets < <(
  awk '
    /^build-gate:/ { in_recipe=1; next }
    in_recipe && /^[a-zA-Z0-9_-]+:/ { exit }
    in_recipe { print }
  ' justfile \
    | grep -oE '\.#checks\.x86_64-linux\.[a-z0-9-]+'
)

diff -u \
  <(printf '%s\n' "${hosted_targets[@]}") \
  <(printf '%s\n' "${local_targets[@]}")

target=.#checks.x86_64-linux.cli-mock-honesty
test "$(printf '%s\n' "${hosted_targets[@]}" | grep -Fxc "$target")" -eq 1
test "$(printf '%s\n' "${local_targets[@]}" | grep -Fxc "$target")" -eq 1

cli_out=$(nix eval --raw \
  .#checks.x86_64-linux.cli-mock-honesty.outPath)

mapfile -t requested < <(
  nix build --no-link --print-out-paths "${hosted_targets[@]}"
)

nix path-info -r "${requested[@]}" \
  | sort -u \
  | tee /tmp/epic-55/amaru-bootstrap-70/logs/final-requested-closure.txt

grep -Fx "$cli_out" \
  /tmp/epic-55/amaru-bootstrap-70/logs/final-requested-closure.txt
```

The last command must print the exact evaluated CLI mock honesty output path.

## 3. Seeded failure and exact restoration

Before mutation, record the source hash:

```bash
surface=tests/lib/cli-mock-surface.bash
sha256sum "$surface" \
  | tee /tmp/epic-55/amaru-bootstrap-70/logs/mock-surface-before.sha256
```

Temporarily append `convert-ledger-state` to
`CLI_MOCK_ACCEPTED_AMARU` using a reviewable patch. Then run:

```bash
set +e
nix build -L --rebuild --no-link \
  .#checks.x86_64-linux.cli-mock-honesty \
  2>&1 \
  | tee /tmp/epic-55/amaru-bootstrap-70/logs/seeded-mock-drift.log
rc=${PIPESTATUS[0]}
set -e
test "$rc" -ne 0
grep -F 'convert-ledger-state' \
  /tmp/epic-55/amaru-bootstrap-70/logs/seeded-mock-drift.log
```

Apply the inverse patch immediately. Prove exact restoration before
continuing:

```bash
sha256sum -c \
  /tmp/epic-55/amaru-bootstrap-70/logs/mock-surface-before.sha256
git diff --exit-code -- tests/lib/cli-mock-surface.bash
nix build -L --no-link \
  .#checks.x86_64-linux.cli-mock-honesty \
  2>&1 \
  | tee /tmp/epic-55/amaru-bootstrap-70/logs/restored-cli-mock-honesty.log
```

The seeded build must fail. Hash verification, the scoped diff, and the
restored build must all exit 0.

## 4. Local gates

```bash
just build-gate \
  2>&1 | tee /tmp/epic-55/amaru-bootstrap-70/logs/just-build-gate.log

./gate.sh \
  2>&1 | tee /tmp/epic-55/amaru-bootstrap-70/logs/full-gate.log
```

Both pipelines must return exit 0. The full gate must end with the live Bats
verdict for a producer reading an open cardano-node 10.7.1 ChainDB.

## 5. Hosted pull-request evidence

```bash
gh pr checks 71 --repo lambdasistemi/amaru-bootstrap --watch
gh pr view 71 --repo lambdasistemi/amaru-bootstrap \
  --json headRefOid,statusCheckRollup
```

Resolve the final CI run identifier and capture its log:

```bash
run_id=$(gh run list --repo lambdasistemi/amaru-bootstrap \
  --branch fix/70-cli-mock-honesty-ci-wiring \
  --workflow CI --limit 1 --json databaseId --jq '.[0].databaseId')
gh run view "$run_id" --repo lambdasistemi/amaru-bootstrap --log \
  | tee /tmp/epic-55/amaru-bootstrap-70/logs/hosted-ci.log
grep -F '.#checks.x86_64-linux.cli-mock-honesty' \
  /tmp/epic-55/amaru-bootstrap-70/logs/hosted-ci.log
```

The final PR head must have successful `Build Gate` and
`Live Bootstrap Producer` conclusions, and the log search must print the
requested target.
