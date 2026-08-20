# Data model: rust-overlay nightly availability

Artifact ceiling: 1 KiB

## D84-01 — rust-overlay locked node

- Identity: lock node name `rust-overlay`.
- Source: upstream `oxalica/rust-overlay` on GitHub.
- Immutable fields: resolved commit revision, content hash, and lock
  timestamp metadata.
- Relationship: the node's `nixpkgs` input continues to follow the
  repository root `nixpkgs` input.

Validation: compare parsed lock-node values against base. D84-01 must
change to a revision exposing nightly 2026-08-03; every sibling locked
node and the root input mapping must remain equal.
