{
  description = "Bootstrap data pipeline for Amaru on custom Cardano testnets";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    crane = {
      url = "github:ipetkov/crane";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Amaru does not expose a flake; we wrap its Cargo workspace via crane.
    amaru = {
      url = "github:pragma-org/amaru";
      flake = false;
    };
  };

  outputs =
    { self
    , nixpkgs
    , flake-utils
    , crane
    , amaru
    , ...
    }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        craneLib = (crane.mkLib pkgs);

        # TODO Phase 1: build amaru via craneLib.buildPackage from the
        # `amaru` flake input. Placeholder for now so the flake evaluates.
        amaruPlaceholder = pkgs.runCommand "amaru-placeholder" {} ''
          mkdir -p $out/bin
          echo "#!/usr/bin/env bash" > $out/bin/amaru
          echo "echo 'amaru placeholder — build not yet wired'" >> $out/bin/amaru
          chmod +x $out/bin/amaru
        '';
      in
      {
        packages = {
          amaru = amaruPlaceholder;
          default = amaruPlaceholder;
        };

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            just
            jq
          ];
        };
      });
}
