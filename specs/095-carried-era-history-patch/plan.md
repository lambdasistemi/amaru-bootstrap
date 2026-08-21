# Plan: carried era-history bootstrap patch

Artifact ceiling: 90 lines.

## Constraints

- A-EPIC-003 is the narrow governing amendment to constitution principles I
  and II; all other constitution constraints remain binding.
- The upstream source is the bare SHA `ba992f651d3b5e2b49f12d461b86ab8f7a55f994`.
- The patch is a Nix build input, not a fork, branch, vendored tree, or runtime
  source substitution.
- The PR 93 fixture blobs are immutable; candidate-only paths form the explicit
  integration delta.
- Zero local Nix realization. Build, package, image, and live proof are hosted.
- No upstream publication. Findings for upstream remain local operator packets.

## Strategy

Carry the smallest upstream-shaped source delta: mirror `node run`'s era
history option at `node bootstrap`, load the effective built-in-or-file value
at the CLI boundary, and pass it through the public bootstrap API to snapshot
epoch mapping. Keep all snapshot validation, selection, import, nonce, header,
ledger, and chain-store behavior owned by upstream Amaru.

Apply the patch in `nix/amaru.nix` with an explicit base-SHA assertion and
declared patch digest. Expose their joined identity on the package and add an
executable retirement guard. Wire the producer to its staged
`era-history.json`; strengthen strict mock and negative-control proof without
changing accepted command paths.

## Ordered slice

One bisect-safe OWNER slice contains the inseparable source patch, Nix identity
binding, producer invocation, permanent proof, and exact PR 93 fixture blobs.
The commit owner first records a complete non-realizing RED bundle, then makes
the minimal candidate and verifies static/mock gates. A fresh alternate-family
auditor checks every invariant. Realizing proof starts only after the audited
commit is pushed and is supplied by GitHub Actions.

## Verification boundary

Local evidence: Git provenance/blob identity, patch/digest reconciliation,
shell syntax/lint, focused Bats mocks, static Nix evaluation when it does not
realize, and deliberate gate mutants. Hosted evidence: Amaru build, all flake
checks, image build/load, exact ChainDB producer, and live consumer startup.

## Constitution check

- The explicit registry amendment authorizes only this SHA-bound patch.
- No consensus/bootstrap behavior is reimplemented locally.
- All source and image identities remain immutable and reviewable.
- The executable retirement guard prevents the exception becoming invisible
  or permanent after upstream equivalence.
