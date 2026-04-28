{ project }:

# Extract the three stock IOG executables we orchestrate from the
# pinned ouroboros-consensus source-repository-package. These are
# upstream, unmodified — constitution Principle II mode (a).
#
# All three exes live in the ouroboros-consensus-cardano package;
# targets verified at
# https://github.com/IntersectMBO/ouroboros-consensus/blob/release-ouroboros-consensus-0.27.0.0/ouroboros-consensus-cardano/ouroboros-consensus-cardano.cabal
let
  exes = project.hsPkgs.ouroboros-consensus-cardano.components.exes;
in
{
  db-synthesizer = exes.db-synthesizer;
  db-analyser = exes.db-analyser;
  snapshot-converter = exes.snapshot-converter;
}
