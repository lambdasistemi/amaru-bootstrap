#!/usr/bin/env bash
set -euo pipefail

git diff --check
nix flake check --no-update-lock-file
just build-gate
