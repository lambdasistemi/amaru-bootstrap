{ pkgs
, CHaP
}:

# haskell.nix project: marker package `amaru-bootstrap` plus the
# IntersectMBO/ouroboros-consensus source-repository-package pinned in
# cabal.project. Provides hsPkgs for downstream consumers (most
# importantly the db-synthesizer and db-analyser exes in
# ouroboros-consensus-cardano).
let
  # cardano-crypto-praos and cardano-crypto-class declare pkg-config
  # dependencies on libsodium / secp256k1 / libblst; iohk-nix supplies
  # the actual derivations and we wire them in via an haskell.nix
  # module override. Without this, the cabal solver fails with
  # "pkg-config package libblst-any, not found".
  fix-libs = { lib, pkgs, ... }: {
    packages.cardano-crypto-praos.components.library.pkgconfig =
      lib.mkForce [ [ pkgs.libsodium-vrf ] ];
    packages.cardano-crypto-class.components.library.pkgconfig =
      lib.mkForce [ [ pkgs.libsodium-vrf pkgs.secp256k1 pkgs.libblst ] ];
  };
in
pkgs.haskell-nix.cabalProject' {
  name = "amaru-bootstrap";

  src = pkgs.haskell-nix.haskellLib.cleanSourceWith {
    name = "amaru-bootstrap-src";
    src = ../.;
    filter = path: _type:
      builtins.match ".*\\.(cabal|hs|project|md)$" path != null
        || builtins.match ".*/lib(/.*)?$" path != null
        || builtins.match ".*/app(/.*)?$" path != null
        || builtins.match ".*/test(/.*)?$" path != null
        || builtins.match ".*/cabal\\.project$" path != null
        || builtins.match ".*/LICENSE$" path != null;
  };

  compiler-nix-name = "ghc967";

  inputMap = {
    "https://chap.intersectmbo.org/" = CHaP;
  };

  modules = [ fix-libs ];

  shell = {
    withHoogle = false;
    tools = {
      cabal = "latest";
    };
    buildInputs = with pkgs; [
      jq
      shellcheck
    ];
  };
}
