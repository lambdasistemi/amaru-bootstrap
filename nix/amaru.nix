{ pkgs
, crane
, amaru
}:

# crane-built amaru binary, wrapping the pragma-org/amaru flake input.
# amaru exposes no flake of its own. SHA pinning happens via flake.lock
# on the `amaru` input — constitution Principle III.
#
# We honour amaru's own rust-toolchain.toml so the rustc version
# matches whatever upstream is testing against; nixpkgs-unstable's
# stock rustc lags behind by one or two minor versions.
let
  rustToolchain = pkgs.rust-bin.fromRustupToolchainFile
    "${amaru}/rust-toolchain.toml";
  craneLib = (crane.mkLib pkgs).overrideToolchain rustToolchain;
in
craneLib.buildPackage {
  pname = "amaru";
  version = "0.1.2";

  src = craneLib.cleanCargoSource amaru;
  strictDeps = true;

  # Build only the amaru binary; its sibling crates in the workspace
  # build as transitive deps as needed.
  # NB: crane already adds --release for buildPackage, so don't repeat
  # it here — cargo errors out on duplicate --release flags.
  cargoExtraArgs = "--package amaru";
  doCheck = false;

  # m4 / autoconf / automake required by some sys-* crates (gmp,
  # libsodium-sys, etc.) when their build.rs invokes ./configure.
  # bindgen-pulled crates pull libclang.
  nativeBuildInputs = with pkgs; [
    pkg-config
    m4
    autoconf
    automake
    libtool
    cmake
  ];

  buildInputs = with pkgs; [
    openssl
  ];

  LIBCLANG_PATH = "${pkgs.llvmPackages.libclang.lib}/lib";
}
