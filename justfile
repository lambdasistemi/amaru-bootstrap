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
        .#checks.x86_64-linux.ledger-state-emitter \
        .#checks.x86_64-linux.shellcheck \
        .#checks.x86_64-linux.smoke-test-bats \
        .#checks.x86_64-linux.header-extractor-spec \
        .#checks.x86_64-linux.header-extractor-cli-bats \
        .#checks.x86_64-linux.bootstrap-producer-bats \
        .#checks.x86_64-linux.bootstrap-producer-synthesized \
        .#checks.x86_64-linux.amaru-run-bootstrap \
        .#checks.x86_64-linux.bootstrap-producer-image

# Run the unit-style bats checks.
bats:
    nix build --quiet .#checks.x86_64-linux.smoke-test-bats

# Run the Docker-level live cardano-node verifier. This is intentionally
# outside `build-gate` because it needs a Docker daemon.
live-bootstrap-producer:
    #!/usr/bin/env bash
    set -euo pipefail
    nix build --quiet \
        .#packages.x86_64-linux.bootstrap-producer-image \
        -o result-bootstrap-producer-image
    nix --quiet shell nixpkgs#docker-client \
        -c docker load -i result-bootstrap-producer-image
    BOOTSTRAP_PRODUCER_IMAGE=amaru-bootstrap-producer:dev \
    CARDANO_NODE_IMAGE=ghcr.io/intersectmbo/cardano-node:10.7.1 \
        nix --quiet shell \
            .#checks.x86_64-linux.db-synthesizer \
            nixpkgs#bash \
            nixpkgs#bats \
            nixpkgs#coreutils \
            nixpkgs#findutils \
            nixpkgs#gnugrep \
            nixpkgs#jq \
            nixpkgs#docker-client \
            -c bats --tap tests/test-bootstrap-producer-live.bats

# Lint scripts/smoke-test.sh.
shellcheck:
    nix build --quiet .#checks.x86_64-linux.shellcheck

# Mirror the GitHub CI workflow: build gate then the verdict run.
ci:
    #!/usr/bin/env bash
    set -euo pipefail
    just build-gate
    out_dir="./tmp/smoke-out"
    verdict_log="./tmp/smoke-verdict.log"
    rm -rf "$out_dir" "$verdict_log"
    mkdir -p ./tmp
    set +e
    nix run --quiet .#smoke-test -- \
        specs/001-snapshot-format-smoke/fixtures/p1-config \
        "$out_dir" \
        2>&1 | tee "$verdict_log"
    smoke_rc=${PIPESTATUS[0]}
    set -e
    verdict="$(tail -n 1 "$verdict_log")"
    printf 'smoke rc=%s verdict=%s\n' "$smoke_rc" "$verdict"
    case "$verdict" in
        PASS|"FAIL: format mismatch")
            ;;
        *)
            printf 'Phase 0 verdict not reached: %s\n' "$verdict" >&2
            exit 1
            ;;
    esac
    just live-bootstrap-producer
