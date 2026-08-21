# Modules model

Artifact ceiling: 50 lines.

| ID | Component | Responsibility change | Dependency direction |
|---|---|---|---|
| M-091-PRODUCER | `scripts/bootstrap-producer.sh` | Recognize the selected upstream Amaru snapshot artifact form while preserving the minimum-target failure boundary. | Depends on the filesystem output of pinned `amaru snapshot create`; MUST leave archive validation/import to upstream Amaru. |
| M-091-PROOF | Producer mock regression suites | Prove both accepted forms and the no-artifact drift failure over the real producer control path. | Depends on the producer interface and existing strict CLI mock registry; MUST NOT redefine the real CLI surface. |
| M-091-CHECKS | Snapshot-layout consumers in `nix/checks.nix` | Assert the same accepted-form/minimum-count contract before downstream bundle checks. | Depends on the produced bundle; MUST retain `cli-mock-honesty` as an independent reconciliation check. |

No new component or abstraction is introduced.
