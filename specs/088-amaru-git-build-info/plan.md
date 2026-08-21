# Plan: deterministic Amaru git build information

Artifact ceiling: 100 lines.

## Constraints

- Constitution I/II: consume stock upstream source; no fork, vendoring, or
  upstream patch set.
- Constitution III: identity originates only from the locked SHA.
- Constitution IV: package and proof remain Nix-owned.
- Host STOP condition: no local Nix realization; hosted CI supplies all build
  and runtime proof.
- PR #87 remains open and untouched as fire evidence.

## Strategy

The Amaru package boundary owns deterministic source identity. It exposes the
same locked full revision, eight-character short revision, and clean status to
the stock and candidate upstream build-script shapes without supplying Git
metadata. The existing `amaru` flake check becomes an executable identity
check while retaining a dependency on the actual package build.

## Ordered slice

One bisect-safe slice covers the package identity boundary and its permanent
check. The commit owner supplies a RED proof that the pre-change package lacks
the required deterministic bridge, then implements the smallest compatible
boundary and a check that rejects mismatched or dirty version output.

After independent audit and finalization, the ticket owner pushes the stock
pin issue branch for hosted CI. A separate temporary fixture branch adds the
accepted fix to PR #87's exact two-file delta and receives its own hosted CI
run. The fixture never advances or modifies PR #87.

## Verification boundary

Local verification is limited to Git, textual/static checks, Nix parsing or
evaluation that does not realize derivations, and exact-tree provenance.
Package builds, binary execution inside Nix checks, and full repository CI
are accepted only from hosted GitHub Actions receipts.

## Constitution check

- No upstream fork or source mutation.
- Custom logic is confined to the replaceable Nix packaging boundary.
- All identity values derive from the immutable lock revision.
- No moving tag, `leaveDotGit`, impure fetcher, or networked build step.
