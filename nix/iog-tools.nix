{ project }:

# Extract the three stock IOG executables we orchestrate from the
# pinned ouroboros-consensus source-repository-package. All upstream,
# unmodified — constitution Principle II.
#
# Targets all live in ouroboros-consensus-cardano. Verified at
# https://github.com/IntersectMBO/ouroboros-consensus/blob/release-ouroboros-consensus-0.27.0.0/ouroboros-consensus-cardano/ouroboros-consensus-cardano.cabal
let
  exes = project.hsPkgs.ouroboros-consensus-cardano.components.exes;
in
{
  db-synthesizer = exes.db-synthesizer;
  db-analyser = exes.db-analyser;
  # Phase 1 bridge: converts the V2InMemory directory snapshot
  # db-analyser writes into the legacy single-file format amaru's
  # convert-ledger-state consumes. Same upstream package, same SHA;
  # zero new dependencies. Resolves Phase 0's FAIL: format mismatch
  # without writing custom Haskell — an honest application of
  # constitution Principle II.
  snapshot-converter = exes.snapshot-converter;
}
