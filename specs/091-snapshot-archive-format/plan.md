# Plan: snapshot archive format compatibility

Artifact ceiling: 80 lines.

## Constraints

- Constitution I/II: adapt local orchestration around unmodified upstream
  tools; do not fork, patch, or vendor Amaru.
- Constitution III/IV: retain SHA pinning and the Nix-owned Build Gate.
- The producer/runtime freeze exception is limited to the snapshot-format
  interface and its direct layout consumers.
- Zero local Nix realization; all build, package, and full-CI proof is hosted.
- `cli-mock-honesty` retains its current meaning and Build Gate reachability.

## Strategy

Keep both upstream artifact forms as a compatibility boundary. The producer
and direct layout-inspecting checks share the same observable filename and
minimum-count contract, while the pinned `amaru node bootstrap` remains the
owner of consuming and validating the selected upstream representation.

## Ordered slice

One bisect-safe slice adapts producer snapshot recognition, permanent mock
regression proof, and direct flake-check consumers. The commit owner first
demonstrates the directory-only baseline rejecting archive output and the
empty-output negative control, then supplies the smallest format adaptation.

After fresh audit and exact-tree finalization, hosted CI proves the stock pin.
A separate evidence-only fixture branch applies PR #90's exact two-file delta
on the accepted fix and proves the candidate pin. The fixture PR is never
merged and PR #90 remains untouched.

## Verification boundary

Local evidence is limited to Git provenance, Bash parsing/static analysis,
mock-based focused tests, Nix evaluation without realization, and gate
falsification. GitHub Actions supplies all Nix realization, Build Gate, image,
and live-boundary evidence.

## Constitution check

- No dependency or upstream-source changes on the issue branch.
- No new runtime tool or custom archive decoder.
- Both behaviors follow the exact selected Amaru SHA.
- No moving tag, publication identity, or peer-snapshot change.
