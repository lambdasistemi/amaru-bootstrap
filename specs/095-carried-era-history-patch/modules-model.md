# Modules model

Artifact ceiling: 55 lines.

| ID | Component | Responsibility change | Dependency direction |
|---|---|---|---|
| M-095-PATCH | Repository-versioned Amaru patch | Expose the existing era-history input shape at `node bootstrap` and carry the effective value to bootstrap snapshot mapping. | Depends only on exact bare upstream Amaru; MUST NOT add bootstrap/store behavior. |
| M-095-NIX | `nix/amaru.nix` and its checks | Apply M-095-PATCH and bind upstream SHA plus patch SHA-256 into package identity and retirement enforcement. | Depends on the pinned flake input and patch asset; MUST fail closed on identity drift. |
| M-095-PRODUCER | `scripts/bootstrap-producer.sh` | Supply the already-derived staged era-history file to patched `node bootstrap`. | Depends on the patched CLI; MUST leave snapshot/store semantics to Amaru. |
| M-095-PROOF | Strict bootstrap mock suites and flake checks | Prove argument/path reconciliation, failure classes, identity, fixture integrity, and retirement reachability. | Depends on M-095-PATCH/NIX/PRODUCER and the real hosted binary; MUST preserve existing CLI guard meaning. |

No new runtime component or local bootstrap abstraction is introduced.
