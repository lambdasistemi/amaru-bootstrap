# Modules model

Artifact ceiling: 60 lines.

| ID | Component | Responsibility change | Dependency direction |
|---|---|---|---|
| M-088-PKG | `nix/amaru.nix` | Supply deterministic locked git identity at the upstream build boundary for every Amaru package variant. | May depend on `amaruRev`; MUST NOT depend on repository metadata, network, or peer-snapshot state for identity. |
| M-088-CHECK | `nix/checks.nix` | Execute the packaged version surface and reject missing, mismatched, or dirty identity. | Depends on `amaruPkg` and `amaruRev`; MUST remain independent of PR #87 fixture state. |

No new component or abstraction is introduced. `flake.nix` continues to pass
the locked revision into both package and checks.
