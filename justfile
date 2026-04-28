# shellcheck shell=bash

set unstable := true

# List available recipes.
default:
    @just --list

# Run the smoke test against the vendored fixture (the Phase 0
# default). Out-dir defaults to ./tmp/smoke-out.
smoke out="./tmp/smoke-out":
    #!/usr/bin/env bash
    set -euo pipefail
    rm -rf "{{ out }}"
    nix run --quiet .#smoke-test -- \
        specs/001-snapshot-format-smoke/fixtures/p1-config \
        "{{ out }}"

# Run the smoke test against an arbitrary bundle.
smoke-bundle bundle out:
    #!/usr/bin/env bash
    set -euo pipefail
    rm -rf "{{ out }}"
    nix run --quiet .#smoke-test -- "{{ bundle }}" "{{ out }}"

# Build all flake checks that have binary outputs. Mirrors the CI
# Build Gate exactly.
build-gate:
    #!/usr/bin/env bash
    set -euo pipefail
    nix build --quiet \
        .#checks.x86_64-linux.amaru \
        .#checks.x86_64-linux.db-synthesizer \
        .#checks.x86_64-linux.db-analyser \
        .#checks.x86_64-linux.shellcheck \
        .#checks.x86_64-linux.smoke-test-bats \
        .#checks.x86_64-linux.header-extractor-spec \
        .#checks.x86_64-linux.header-extractor-cli-bats \
        .#checks.x86_64-linux.bootstrap-producer-bats

# Run the unit-style bats checks.
bats:
    nix build --quiet .#checks.x86_64-linux.smoke-test-bats

# Lint scripts/smoke-test.sh.
shellcheck:
    nix build --quiet .#checks.x86_64-linux.shellcheck

# Mirror the GitHub CI workflow: build gate then the verdict run.
ci:
    #!/usr/bin/env bash
    set -euo pipefail
    just build-gate
    just smoke
