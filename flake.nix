{
  description = "Bootstrap data pipeline for Amaru on custom Cardano testnets";

  nixConfig = {
    extra-substituters = [
      "https://cache.iog.io"
      "https://paolino.cachix.org"
    ];
    extra-trusted-public-keys = [
      "hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ="
      "paolino.cachix.org-1:m/ddECNNFmjffrlmCFf3PPoffp46zU0wgoyz1Bj7Wjg="
    ];
  };

  inputs = {
    haskellNix.url = "github:input-output-hk/haskell.nix";
    nixpkgs.follows = "haskellNix/nixpkgs-unstable";
    flake-utils.url = "github:hamishmack/flake-utils/hkm/nested-hydraJobs";

    # iohk-nix supplies the crypto pkgs (libsodium-vrf, secp256k1,
    # libblst) that cardano-crypto-class and cardano-crypto-praos need
    # via pkg-config — without these overlays haskell.nix's cabal
    # solver cannot resolve those packages.
    iohkNix = {
      url = "github:input-output-hk/iohk-nix";
      inputs.nixpkgs.follows = "nixpkgs";
      # Pin blst to the v0.3.14 tag rev. iohk-nix's crypto overlay expects
      # blst 0.3.14, but the default (v0.3.15) rev now serves drifted tarball
      # content under the same SHA, intermittently breaking the flake.lock
      # narHash both locally and in CI ("regional content shift"). 8c7db7fe is
      # the v0.3.14 tag and hashes deterministically to the expected content.
      inputs.blst = {
        url = "github:supranational/blst/8c7db7fe8d2ce6e76dc398ebd4d475c0ec564355";
        flake = false;
      };
    };

    # CHaP — read-only, consumed by haskell.nix as the cabal index for
    # cardano-* packages. Pinned via flake.lock.
    CHaP = {
      url = "github:intersectmbo/cardano-haskell-packages?ref=repo";
      flake = false;
    };

    # crane wraps amaru's Cargo workspace. amaru does not expose its
    # own flake.
    crane.url = "github:ipetkov/crane";

    # rust-overlay supplies the rustc version amaru's rust-toolchain.toml
    # pins (currently 1.97); nixpkgs-unstable lags behind upstream Rust
    # releases so the stock pkgs.rustc fails amaru's solver.
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # lambdasistemi/amaru consumed as a non-flake input; SHA pinned via
    # flake.lock per constitution Principle III. Pinned to feat/testnet-bootstrap:
    # upstream pragma-org/amaru main plus a minimal, upstreamable delta —
    # create-snapshots --targets-file/--cardano-db-dir (offline/testnet snapshots),
    # runtime --era-history-file/--global-parameters-file, the testnet tvar
    # era-history sidecar fix, and short-epoch ledger/consensus guards.
    amaru = {
      url = "github:lambdasistemi/amaru/4165a5f4ce3f64a9819e0bb97276f82c7db52d5b";
      flake = false;
    };
  };

  outputs =
    inputs@{ self
    , nixpkgs
    , flake-utils
    , haskellNix
    , iohkNix
    , CHaP
    , crane
    , rust-overlay
    , amaru
    , ...
    }:
    flake-utils.lib.eachSystem [ "x86_64-linux" ] (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          inherit (haskellNix) config;
          overlays = [
            iohkNix.overlays.crypto
            haskellNix.overlay
            iohkNix.overlays.haskell-nix-crypto
            (import rust-overlay)
          ];
        };

        project = import ./nix/project.nix { inherit pkgs CHaP; };
        amaruPkg = import ./nix/amaru.nix { inherit pkgs crane amaru; };
        iogTools = import ./nix/iog-tools.nix { inherit project; };
        headerExtractorPkgs = import ./nix/header-extractor.nix { inherit project; };
        bootstrapProducerImage = import ./nix/bootstrap-producer-image.nix {
          inherit pkgs amaruPkg iogTools;
          headerExtractor = headerExtractorPkgs.header-extractor;
          ledgerStateEmitter = headerExtractorPkgs.ledger-state-emitter;
        };
        checks = import ./nix/checks.nix {
          inherit pkgs amaruPkg iogTools headerExtractorPkgs bootstrapProducerImage;
        };
        apps = import ./nix/apps.nix {
          inherit pkgs amaruPkg iogTools headerExtractorPkgs;
        };
        shell = import ./nix/shell.nix {
          inherit pkgs project amaruPkg iogTools;
        };
      in
      {
        packages = {
          amaru = amaruPkg;
          db-synthesizer = iogTools.db-synthesizer;
          db-analyser = iogTools.db-analyser;
          snapshot-converter = iogTools.snapshot-converter;
          header-extractor = headerExtractorPkgs.header-extractor;
          ledger-state-emitter = headerExtractorPkgs.ledger-state-emitter;
          bootstrap-producer-image = bootstrapProducerImage;
          default = amaruPkg;
        };

        inherit checks apps;

        devShells.default = shell;
      });
}
