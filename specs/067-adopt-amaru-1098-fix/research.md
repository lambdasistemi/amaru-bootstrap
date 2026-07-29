# Research: Adopt the Amaru Consensus Fix

## R-001 - Freeze bare upstream main

**Decision**: Capture `refs/heads/main` directly with `git ls-remote` just
before the edit and use its immutable full SHA.

**Rationale**: This satisfies SHA pinning without trusting a moving branch.
The target must contain the known #1098 squash merge `437ff6c4`.

## R-002 - Rebuild the squashed tree

**Decision**: Treat the preview proof as compatibility evidence only and
run the complete selected-source build and live gate again.

**Rationale**: Upstream squash commit `437ff6c4` has a different tree and
history from preview head `b077d1d`; ancestry cannot transfer build proof.

## R-003 - Change only the Amaru input

**Decision**: Edit the declaration, let Nix update the named input, and
structurally compare the lock file with `.nodes.amaru` removed.

**Rationale**: Nix owns generated source metadata while the structural
comparison detects unrelated dependency movement.

## R-004 - Reuse permanent compatibility instruments

**Decision**: Seed one rejected accepted-command declaration to prove the
CLI invariant fails closed, restore it, then use the real selected binary,
Build Gate, and Docker verifier as GREEN.

**Rationale**: These existing instruments cover the declared command seam
and the live-system seam without adding a duplicate hard-coded pin test.

## R-005 - Publish an immutable PR image

**Decision**: After required hosted checks succeed, inspect the existing
same-repository PR tag and record its exact digest.

**Rationale**: The downstream test needs a reproducible supplier artifact,
not a local image or an unqualified tag.

## R-006 - Keep the payoff honest

**Decision**: This supplier PR tracks, but does not close, issue #67. It
asks the desk for merge authorization after image publication; the separate
Antithesis run remains required before the issue is complete.

**Rationale**: Image compatibility is necessary but cannot prove behavior
under fault injection.
