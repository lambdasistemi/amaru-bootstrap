#!/usr/bin/env bash
set -euo pipefail

git diff --check
nix flake check
just live-bootstrap-producer
