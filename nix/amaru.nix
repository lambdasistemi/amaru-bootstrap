{ pkgs
, crane
, amaru
, amaruRev
, cardano-configurations
, cardanoConfigurationsRev
, peerSnapshots ? "pinned"
, peerSnapshotFault ? null
, cargoArtifacts ? null
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

  supportedPeerSnapshots = [ "pinned" "placeholder-dev" ];
  supportedPeerSnapshotFaults = [ null ] ++ import ./peer-snapshot-faults.nix;

  peerSnapshotResolution =
    builtins.fromJSON (builtins.readFile ./peer-snapshots/resolution.json);

  # Explicit development-only peer-snapshot placeholders.
  # workaround-for=https://github.com/pragma-org/amaru/issues/1102
  # amaru-node's build.rs embeds a peer snapshot for mainnet, preprod and
  # preview and hard-fails when none is staged; its fetch path also shells
  # out to `git show`, which fails in a clean source archive. Upstream only
  # fs::copy's the staged file into OUT_DIR. This fallback is exposed only
  # as packages.<system>.amaru-placeholder-dev; production consumers use
  # the pinned upstream files below. Staging is additive only.
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
assert builtins.elem peerSnapshots supportedPeerSnapshots;
assert builtins.elem peerSnapshotFault supportedPeerSnapshotFaults;
assert peerSnapshots == "pinned" || peerSnapshotFault == null;
craneLib.buildPackage ({
  pname = "amaru" + pkgs.lib.optionalString (peerSnapshots == "placeholder-dev")
    "-placeholder-dev" + pkgs.lib.optionalString (peerSnapshotFault != null)
    "-${peerSnapshotFault}";
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
    check-jsonschema
    jq
  ];

  buildInputs = with pkgs; [
    openssl
  ];

  LIBCLANG_PATH = "${pkgs.llvmPackages.libclang.lib}/lib";

  # workaround-for=https://github.com/pragma-org/amaru/issues/1102
  # Skip the build-time peer-snapshot network/Git-date fetch; the staged
  # snapshots below satisfy the unconditional presence check. env_flag
  # accepts only 1/true/TRUE/yes/YES — use exactly "1".
  AMARU_SKIP_PEER_SNAPSHOT_FETCH = "1";

  # Stage peer snapshots where amaru-node's build.rs looks for them.
  # cleanCargoSource drops these non-Cargo files, so staging and validation
  # happen after the clean source has been unpacked. The schema deliberately
  # comes from the raw pinned amaru input, not the cleaned source.
  preBuild = ''
    snapshot_dir=crates/amaru-node/config/peer-snapshots
    ${if peerSnapshots == "pinned" then ''
      for network in mainnet preprod preview; do
        install -D -m 0644 \
          ${cardano-configurations}/network/$network/cardano-node/peer-snapshot.json \
          "$snapshot_dir/$network/peer-snapshot.json"
      done
      printf 'sha: %s\n' '${cardanoConfigurationsRev}' \
        >"$snapshot_dir/CONFIGS_COMMIT_CACHE"
    '' else ''
      install -D -m 0644 ${peerSnapshot 764824073} \
        "$snapshot_dir/mainnet/peer-snapshot.json"
      install -D -m 0644 ${peerSnapshot 1} \
        "$snapshot_dir/preprod/peer-snapshot.json"
      install -D -m 0644 ${peerSnapshot 2} \
        "$snapshot_dir/preview/peer-snapshot.json"
    ''}

    ${pkgs.lib.optionalString (peerSnapshotFault == "missing-mainnet") ''
      rm "$snapshot_dir/mainnet/peer-snapshot.json"
    ''}
    ${pkgs.lib.optionalString (peerSnapshotFault == "invalid-schema-preprod") ''
      printf '{}\n' >"$snapshot_dir/preprod/peer-snapshot.json"
    ''}
    ${pkgs.lib.optionalString (peerSnapshotFault == "wrong-magic-preview") ''
      jq '.NetworkMagic = 1' "$snapshot_dir/preview/peer-snapshot.json" \
        >"$snapshot_dir/preview/peer-snapshot.json.tmp"
      mv "$snapshot_dir/preview/peer-snapshot.json.tmp" \
        "$snapshot_dir/preview/peer-snapshot.json"
    ''}
    ${pkgs.lib.optionalString (peerSnapshotFault == "empty-pools-mainnet") ''
      jq '.bigLedgerPools = []' "$snapshot_dir/mainnet/peer-snapshot.json" \
        >"$snapshot_dir/mainnet/peer-snapshot.json.tmp"
      mv "$snapshot_dir/mainnet/peer-snapshot.json.tmp" \
        "$snapshot_dir/mainnet/peer-snapshot.json"
    ''}
    ${pkgs.lib.optionalString (peerSnapshotFault == "tampered-staged-mainnet") ''
      printf '\n' >>"$snapshot_dir/mainnet/peer-snapshot.json"
    ''}

    ${pkgs.lib.optionalString (peerSnapshots == "pinned") ''
      if [ '${peerSnapshotResolution.amaru_rev}' != '${amaruRev}' ]; then
        echo "peer-snapshot anchor failed: amaru rev ${amaruRev} does not match record ${peerSnapshotResolution.amaru_rev}" >&2
        exit 1
      fi
      if [ '${peerSnapshotResolution.configs_rev}' != '${cardanoConfigurationsRev}' ]; then
        echo "peer-snapshot anchor failed: configs rev ${cardanoConfigurationsRev} does not match record ${peerSnapshotResolution.configs_rev}" >&2
        exit 1
      fi

      schema=${amaru}/crates/amaru-node/config/peer-snapshots/peer-snapshot.schema.json
      validate_snapshot() {
        local network=$1
        local expected_magic=$2
        local expected_sha256=$3
        local snapshot="$snapshot_dir/$network/peer-snapshot.json"

        if [ ! -f "$snapshot" ]; then
          echo "peer-snapshot validation failed: $network: missing staged file" >&2
          return 1
        fi
        if ! check-jsonschema --schemafile "$schema" "$snapshot"; then
          echo "peer-snapshot validation failed: $network: schema violation" >&2
          return 1
        fi
        if ! jq -e --argjson expected "$expected_magic" \
          '.NetworkMagic == $expected' "$snapshot" >/dev/null; then
          echo "peer-snapshot validation failed: $network: expected NetworkMagic $expected_magic" >&2
          return 1
        fi
        if ! jq -e '.bigLedgerPools | type == "array" and length > 0' \
          "$snapshot" >/dev/null; then
          echo "peer-snapshot validation failed: $network: bigLedgerPools is empty" >&2
          return 1
        fi
        local actual_sha256
        actual_sha256=$(sha256sum "$snapshot" | cut -d' ' -f1)
        if [ "$actual_sha256" != "$expected_sha256" ]; then
          echo "peer-snapshot validation failed: $network: sha256 does not match anchored record" >&2
          echo "  staged:   $actual_sha256" >&2
          echo "  anchored: $expected_sha256" >&2
          return 1
        fi
        echo "peer-snapshot validation passed: $network"
      }

      validate_snapshot mainnet 764824073 \
        '${peerSnapshotResolution.snapshots.mainnet.sha256}'
      validate_snapshot preprod 1 \
        '${peerSnapshotResolution.snapshots.preprod.sha256}'
      validate_snapshot preview 2 \
        '${peerSnapshotResolution.snapshots.preview.sha256}'
    ''}
  '';
} // pkgs.lib.optionalAttrs (cargoArtifacts != null) {
  inherit cargoArtifacts;
})
