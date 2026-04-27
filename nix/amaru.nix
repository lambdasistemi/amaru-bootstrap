{ pkgs
, crane
, amaru
}:

# crane-built amaru binary, wrapping the pragma-org/amaru flake input.
# amaru exposes no flake of its own. SHA pinning happens via flake.lock
# on the `amaru` input — constitution Principle III.
let
  craneLib = crane.mkLib pkgs;
in
craneLib.buildPackage {
  pname = "amaru";
  version = "0.1.2";

  src = craneLib.cleanCargoSource amaru;
  strictDeps = true;

  # Build only the amaru binary; its sibling crates in the workspace
  # build as transitive deps as needed.
  cargoExtraArgs = "--package amaru --release";
  doCheck = false;

  nativeBuildInputs = with pkgs; [
    pkg-config
  ];

  buildInputs = with pkgs; [
    openssl
  ];
}
