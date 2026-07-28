{ project }:

# Extract the in-repo `header-extractor` executable plus the
# `header-extractor-spec` test-suite. Per amended constitution v1.1.0
# Principle II "mode (b)", the executable is a small library-consumer
# of `ouroboros-consensus` — not a fork.
#
# The test-suite is exposed alongside the exe so nix/checks.nix can
# wrap it in a derivation that synthesises a chain DB before invoking
# it (the spec needs the chain DB to exercise tipInfo / listBlocks /
# getHeader against real input).
#
# Reference: see
# specs/003-amaru-bootstrap-producer/research.md R-001 + R-009 + R-010.
let
  components = project.hsPkgs.amaru-bootstrap.components;
in
{
  header-extractor = components.exes.header-extractor;
  header-extractor-spec = components.tests.header-extractor-spec;
}
