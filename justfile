# shellcheck shell=bash

set unstable := true

# List available recipes.
default:
    @just --list

# Build all flake checks that have binary outputs. Mirrors the CI
# Build Gate exactly.
build-gate:
    #!/usr/bin/env bash
    set -euo pipefail
    nix build --quiet \
        .#checks.x86_64-linux.amaru \
        .#checks.x86_64-linux.peer-snapshot-negative-control \
        .#checks.x86_64-linux.peer-snapshot-anchor \
        .#checks.x86_64-linux.peer-snapshot-anchor-negative-control \
        .#checks.x86_64-linux.db-synthesizer \
        .#checks.x86_64-linux.db-analyser \
        .#checks.x86_64-linux.shellcheck \
        .#checks.x86_64-linux.cli-mock-honesty \
        .#checks.x86_64-linux.db-analyser-points \
        .#checks.x86_64-linux.bootstrap-producer-bats \
        .#checks.x86_64-linux.bootstrap-producer-synthesized \
        .#checks.x86_64-linux.amaru-run-bootstrap \
        .#checks.x86_64-linux.antithesis-short-epoch-samples \
        .#checks.x86_64-linux.antithesis-short-epoch-golden \
        .#checks.x86_64-linux.bootstrap-producer-image

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
    : "${CARDANO_NODE_IMAGE:=ghcr.io/intersectmbo/cardano-node:10.7.1-amd64}"
    export CARDANO_NODE_IMAGE
    BOOTSTRAP_PRODUCER_IMAGE=amaru-bootstrap-producer:dev \
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

# Lint production shell scripts.
shellcheck:
    nix build --quiet .#checks.x86_64-linux.shellcheck

# Re-resolve peer snapshots online at Amaru bump time. Never called by CI.
resolve-peer-snapshots *args:
    nix --quiet shell \
        nixpkgs#curl \
        nixpkgs#jq \
        nixpkgs#coreutils \
        nixpkgs#diffutils \
        -c scripts/resolve-peer-snapshots {{args}}

# Mirror the GitHub CI workflow: build gate then the live verifier.
ci:
    #!/usr/bin/env bash
    set -euo pipefail
    just build-gate
    just live-bootstrap-producer
