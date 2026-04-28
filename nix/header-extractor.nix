{ project }:

# Extract the in-repo `header-extractor` executable. Per amended
# constitution v1.1.0 Principle II "mode (b)", this is a small
# library-consumer of `ouroboros-consensus` — not a fork.
#
# Reference: see
# specs/003-amaru-bootstrap-producer/research.md R-001 + R-009 + R-010.
#
# Mirrors nix/iog-tools.nix's pattern exactly.
let
  exes = project.hsPkgs.amaru-bootstrap.components.exes;
in
{
  header-extractor = exes.header-extractor;
}
