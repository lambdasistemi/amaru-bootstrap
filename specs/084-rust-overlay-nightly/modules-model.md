# Modules model: rust-overlay nightly availability

Artifact ceiling: 1 KiB

## M84-01 — flake input lock

Responsibility changed: `flake.lock` selects the immutable upstream
`rust-overlay` revision used by the existing overlay import in
`flake.nix`.

Dependency direction remains `flake.nix` → locked `rust-overlay` →
the existing Amaru package evaluation. No new module, abstraction, or
dependency edge is introduced.

Data invariants are defined in `data-model.md`. There are no changed
function signatures; see `functions-model.md`.
