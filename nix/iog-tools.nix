{ project }:

# Extract the stock IOG executables we orchestrate from the
# cardano-node 10.7.1-aligned ouroboros-consensus source pin. These
# are upstream, unmodified — constitution Principle II mode (a).
#
# In ouroboros-consensus 3.0.1.0 the former multi-package layout is a
# single package with sublibraries; the exes live under that package.
let
  exes = project.hsPkgs.ouroboros-consensus.components.exes;
in
{
  db-synthesizer = exes.db-synthesizer;
  db-analyser = exes.db-analyser;
  snapshot-converter = exes.snapshot-converter;
}
