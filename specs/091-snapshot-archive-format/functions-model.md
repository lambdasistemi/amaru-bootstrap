# Functions model

Artifact ceiling: 40 lines.

No public function, CLI, exit-code, or runtime signature changes.

The existing shell function contract changes only as follows:

- `phase_create_snapshots() -> process exit/effects`: after successful pinned
  `amaru snapshot create`, accepts D-091-SNAPSHOT-SET and exits 6 when it is
  invalid. It continues to write only inside the producer staging/bundle
  boundary.

Layout-inspecting flake checks consume D-091-SNAPSHOT-SET without adding a new
cross-module function signature.
