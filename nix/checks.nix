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

  headerExtractorTestTree = pkgs.linkFarm "header-extractor-test-tree" [
    { name = "tests"; path = ../tests; }
  ];

  # T012-T016: bats sees the orchestrator script + fixtures + tests/.
  bootstrapProducerTestTree = pkgs.linkFarm "bootstrap-producer-test-tree" [
    { name = "scripts/bootstrap-producer.sh"; path = ../scripts/bootstrap-producer.sh; }
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
    # SC2034: TARGET_SLOT / EPOCH_LENGTH are written by phase_preflight
    # (T018) and read by phase_dump + later (T019). Disable for the
    # T018 commit; the warning auto-clears once T019 lands.
    shellcheck -s bash -e SC1091,SC2034 ${../scripts/bootstrap-producer.sh}
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
        pkgs.coreutils
        headerExtractorPkgs.header-extractor-spec
      ];
    } ''
    set -euo pipefail
    # ImmutableDB needs writable chunk + lock-file paths even for
    # read-only queries. The synthesized chain DB lives in /nix/store
    # which is read-only, so copy it into the build sandbox first.
    cp -rL ${synthesizedChainDb}/chain-db $TMPDIR/chain-db
    chmod -R u+w $TMPDIR/chain-db
    export HEADER_EXTRACTOR_TEST_CHAIN_DB=$TMPDIR/chain-db
    export HEADER_EXTRACTOR_TEST_CONFIG=${fixture}/configs/configs/config.json
    header-extractor-spec
    mkdir -p $out
  '';

  # T006 (failing bats) — CLI-level coverage of the header-extractor
  # binary. Brings the real exe + a synthesised chain DB on-fixture.
  # FAILS until T010 wires the optparse-applicative dispatch.
  header-extractor-cli-bats =
    pkgs.runCommand "header-extractor-cli-bats"
      {
        nativeBuildInputs = [
          pkgs.bash
          pkgs.bats
          pkgs.coreutils
          pkgs.jq
          headerExtractorPkgs.header-extractor
        ];
      } ''
      set -euo pipefail
      cp -rL ${headerExtractorTestTree}/. ./
      chmod -R u+w .
      patchShebangs tests
      # ImmutableDB needs writable chunk + lock-file paths even for
      # read-only queries (see header-extractor-spec for the same
      # workaround).
      cp -rL ${synthesizedChainDb}/chain-db $TMPDIR/chain-db
      chmod -R u+w $TMPDIR/chain-db
      export HEADER_EXTRACTOR_CHAIN_DB=$TMPDIR/chain-db
      export HEADER_EXTRACTOR_CONFIG=${fixture}/configs/configs/config.json
      bats --tap tests/test-header-extractor-cli.bats
      mkdir -p $out
    '';

  # T012-T013: pure-mock bootstrap-producer bats (no real binaries
  # or chain DB needed) - covers the rc=3 (config-error) and rc=1
  # (cluster-not-ready) classes. T014-T016 add chain-DB-dependent
  # checks alongside T019. FAILS until T017+T018 land the script.
  bootstrap-producer-bats =
    pkgs.runCommand "bootstrap-producer-bats"
      {
        nativeBuildInputs = [
          pkgs.bash
          pkgs.bats
          pkgs.coreutils
          pkgs.jq
        ];
      } ''
      set -euo pipefail
      cp -rL ${bootstrapProducerTestTree}/. ./
      chmod -R u+w .
      patchShebangs scripts tests
      bats --tap \
        tests/test-bootstrap-producer-config.bats \
        tests/test-bootstrap-producer-cluster.bats \
        tests/test-bootstrap-producer-idempotent.bats
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
