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

  # Offline peer-snapshot placeholders.
  # workaround-for=https://github.com/pragma-org/amaru/issues/1102
  # amaru-node's build.rs embeds a peer snapshot for mainnet, preprod and
  # preview and hard-fails when none is staged; its fetch path also shells
  # out to `git show`, which fails in a clean source archive. Upstream only
  # fs::copy's the staged file into OUT_DIR (it is never parsed at build
  # time), so a minimal schema-conformant document is enough to let the
  # offline build proceed. Additive staging only — no upstream source is
  # patched, forked or vendored (constitution Principle I).
  peerSnapshot = networkMagic: pkgs.writeText "peer-snapshot.json"
    (builtins.toJSON {
      NetworkMagic = networkMagic;
      NodeToClientVersion = 23;
      Point = {
        blockPointHash =
          "0000000000000000000000000000000000000000000000000000000000000000";
        blockPointSlot = 0;
      };
      bigLedgerPools = [ ];
    });
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

  # workaround-for=https://github.com/pragma-org/amaru/issues/1102
  # Skip the build-time peer-snapshot network/Git-date fetch; the staged
  # placeholders below satisfy the unconditional presence check. env_flag
  # accepts only 1/true/TRUE/yes/YES — use exactly "1".
  AMARU_SKIP_PEER_SNAPSHOT_FETCH = "1";

  # Stage the offline placeholders where amaru-node's build.rs looks for
  # them (additive; the clean source archive ships none). cleanCargoSource
  # would drop merely-added files, so they are generated above and copied
  # in once the real crate tree is present.
  preBuild = ''
    install -D -m 0644 ${peerSnapshot 764824073} \
      crates/amaru-node/config/peer-snapshots/mainnet/peer-snapshot.json
    install -D -m 0644 ${peerSnapshot 1} \
      crates/amaru-node/config/peer-snapshots/preprod/peer-snapshot.json
    install -D -m 0644 ${peerSnapshot 2} \
      crates/amaru-node/config/peer-snapshots/preview/peer-snapshot.json
  '';
}
