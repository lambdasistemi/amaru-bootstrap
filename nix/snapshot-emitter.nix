{ project }:

# Phase 1 bridge tool — extracts the snapshot-emitter executable from
# the haskell.nix project. Same SRP-pinning as iog-tools: no fork of
# ouroboros-consensus, just consume its exposed-modules per
# specs/002-snapshot-emitter/research.md R-001.
project.hsPkgs.amaru-bootstrap.components.exes.snapshot-emitter
