# Functions model

Artifact ceiling: 40 lines.

No public function, CLI, or runtime signature changes.

The existing Nix module contracts remain:

- `nix/amaru.nix` accepts `amaruRev` as a string identifying the immutable
  upstream input and returns an Amaru package derivation.
- `nix/checks.nix` accepts `amaruPkg` and `amaruRev` and returns the flake
  checks attribute set.

The implementation may add private packaging helpers, but they do not create
a new cross-module signature and are intentionally not prescribed here.
