{ pkgs
, amaruPkg
, iogTools
, headerExtractorPkgs
, bootstrapProducerImage
}:

# Flake checks: a derivation per artefact. Each test check builds a
# minimal `bats-runner` source tree at evaluation time using
# pkgs.linkFarm so paths inside the sandbox resolve identically to a
# local checkout (`./scripts`, `./tests`, `./specs/.../fixtures`). This
# avoids surprising path-resolution bugs that came from manually
# stitching files into a runCommand output.
let
  scriptSrc = ../scripts/smoke-test.sh;

  testTree = pkgs.linkFarm "smoke-test-tree" [
    { name = "scripts/smoke-test.sh"; path = scriptSrc; }
    { name = "tests"; path = ../tests; }
    {
      name = "specs/001-snapshot-format-smoke/fixtures";
      path = ../specs/001-snapshot-format-smoke/fixtures;
    }
  ];

  fixture = ../specs/001-snapshot-format-smoke/fixtures/p1-config;

  # Synthesised chain DB used by both the hspec (T005) and bats
  # (T006) header-extractor checks. Nix caches the derivation so
  # the cardano synthesis runs at most once per evaluation.
  synthesizedChainDb = pkgs.runCommand "header-extractor-fixture-chain-db"
    {
      nativeBuildInputs = [
        pkgs.bash
        pkgs.jq
        iogTools.db-synthesizer
      ];
    } ''
    set -euo pipefail

    fixture=${fixture}
    CONFIGS_DIR="$fixture/configs/configs"
    KEYS_DIR="$fixture/configs/keys"

    BULK="$TMPDIR/bulk-credentials.json"
    jq -n \
        --slurpfile opcert "$KEYS_DIR/opcert.cert" \
        --slurpfile vrf    "$KEYS_DIR/vrf.skey" \
        --slurpfile kes    "$KEYS_DIR/kes.skey" \
        '[[ $opcert[0], $vrf[0], $kes[0] ]]' \
        >"$BULK"

    EPOCH_LENGTH=$(jq -r '.epochLength' "$CONFIGS_DIR/shelley-genesis.json")
    SLOTS=$((EPOCH_LENGTH * 2))

    mkdir -p "$out/chain-db"
    db-synthesizer \
        --config "$CONFIGS_DIR/config.json" \
        --bulk-credentials-file "$BULK" \
        -s "$SLOTS" \
        --db "$out/chain-db" \
        -f
  '';
in
{
  amaru = amaruPkg;
  db-synthesizer = iogTools.db-synthesizer;
  db-analyser = iogTools.db-analyser;
  snapshot-converter = iogTools.snapshot-converter;
  header-extractor = headerExtractorPkgs.header-extractor;
  bootstrap-producer-image = bootstrapProducerImage;

  shellcheck = pkgs.runCommand "smoke-test-shellcheck"
    {
      nativeBuildInputs = [ pkgs.shellcheck ];
    } ''
    shellcheck -s bash -e SC1091 ${scriptSrc}
    mkdir -p $out
  '';

  # T005 (failing hspec) — wires the HeaderExtractor library API
  # tests. Reuses the shared synthesised chain DB and runs the hspec
  # exe with env vars pointing to it. FAILS until T007-T009 replace
  # the lib stubs (every spec exits with `error` from a stub body —
  # that's the TDD red, the runCommand then fails which is what we
  # want).
  header-extractor-spec = pkgs.runCommand "header-extractor-spec"
    {
      nativeBuildInputs = [
        pkgs.bash
        headerExtractorPkgs.header-extractor-spec
      ];
    } ''
    set -euo pipefail
    export HEADER_EXTRACTOR_TEST_CHAIN_DB=${synthesizedChainDb}/chain-db
    export HEADER_EXTRACTOR_TEST_CONFIG=${fixture}/configs/configs
    header-extractor-spec
    mkdir -p $out
  '';

  # Unit-style bats: pure mock-based tests, no real binaries needed.
  # Wires T010 + T011 from tasks.md.
  smoke-test-bats = pkgs.runCommand "smoke-test-bats"
    {
      nativeBuildInputs = [ pkgs.bash pkgs.bats pkgs.jq ];
    } ''
    cp -rL ${testTree}/. ./
    chmod -R u+w .
    patchShebangs scripts tests
    bats --tap tests/test-config-error.bats tests/test-tool-error.bats
    mkdir -p $out
  '';

  # Integration: real binaries. THIS is the Phase 0 deliverable —
  # wires T012. Per SC-005, the test has its own 5-minute internal
  # budget; the Nix builder timeout is the outer limit.
  smoke-test-integration = pkgs.runCommand "smoke-test-integration"
    {
      nativeBuildInputs = [
        pkgs.bash
        pkgs.bats
        pkgs.jq
        amaruPkg
        iogTools.db-synthesizer
        iogTools.db-analyser
      ];
    } ''
    cp -rL ${testTree}/. ./
    chmod -R u+w .
    patchShebangs scripts tests
    bats --tap tests/test-smoke-integration.bats
    mkdir -p $out
  '';
}
