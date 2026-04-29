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

  producerRuntimePath = pkgs.lib.makeBinPath [
    pkgs.bash
    pkgs.coreutils
    pkgs.findutils
    pkgs.gawk
    pkgs.jq
    amaruPkg
    headerExtractorPkgs.header-extractor
    headerExtractorPkgs.ledger-state-emitter
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

  # Synthesise a chain DB at <slots> slots against the Phase 0 fixture.
  # Used by:
  #   - synthesizedChainDb     (2 epochs - era-ready, T005/T006/T016)
  #   - shortSynthesizedChainDb (well below 2 epochs - T014's not-era-ready)
  mkSynthesizedChainDb = name: slots: pkgs.runCommand name
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

    SLOTS=${toString slots}

    mkdir -p "$out/chain-db"
    db-synthesizer \
        --config "$CONFIGS_DIR/config.json" \
        --bulk-credentials-file "$BULK" \
        -s "$SLOTS" \
        --db "$out/chain-db" \
        -f
  '';

  # ~3.5 epochs (testnet_42's epochLength = 86400). With the fixture's
  # 5% activeSlotsCoeff the resulting tip lands well past 2*epochLength,
  # so the era-readiness predicate (R-010) holds for T016 + T019.
  synthesizedChainDb =
    mkSynthesizedChainDb "header-extractor-fixture-chain-db" 300000;

  # ~50000 slots - well below 2 * epochLength. Tip exists but the
  # era-readiness predicate stays false, exercising the rc=2 branch
  # (T014).
  shortSynthesizedChainDb =
    mkSynthesizedChainDb "bootstrap-producer-fixture-short-chain-db" 50000;
in
{
  amaru = amaruPkg;
  db-synthesizer = iogTools.db-synthesizer;
  db-analyser = iogTools.db-analyser;
  snapshot-converter = iogTools.snapshot-converter;
  header-extractor = headerExtractorPkgs.header-extractor;
  ledger-state-emitter = headerExtractorPkgs.ledger-state-emitter;
  bootstrap-producer-image = bootstrapProducerImage;

  shellcheck = pkgs.runCommand "smoke-test-shellcheck"
    {
      nativeBuildInputs = [ pkgs.shellcheck ];
    } ''
    shellcheck -s bash -e SC1091 ${scriptSrc}
    shellcheck -s bash -e SC1091 ${../scripts/bootstrap-producer.sh}
    mkdir -p $out
  '';

  # T005: HeaderExtractor library API tests. Reuses the shared
  # synthesized chain DB and runs the hspec exe with env vars pointing
  # to it.
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

  # T006: CLI-level coverage of the header-extractor binary. Brings the
  # real exe plus a synthesized chain DB on-fixture.
  header-extractor-cli-bats =
    pkgs.runCommand "header-extractor-cli-bats"
      {
        nativeBuildInputs = [
          pkgs.bash
          pkgs.bats
          pkgs.coreutils
          pkgs.findutils
          pkgs.gawk
          pkgs.jq
          amaruPkg
          headerExtractorPkgs.header-extractor
          headerExtractorPkgs.ledger-state-emitter
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

  # T012-T015: bootstrap-producer bats. Walks each rc class with the
  # T019 pipeline implementation:
  #   - config (rc=3), cluster (rc=1), idempotent (rc=0): no chain DB
  #   - chain (rc=2): SHORT chain DB via BOOTSTRAP_PRODUCER_CHAIN_DB
  # The full synthesized end-to-end producer path is checked separately
  # below because it builds and imports a real bundle.
  bootstrap-producer-bats =
    pkgs.runCommand "bootstrap-producer-bats"
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
      cp -rL ${bootstrapProducerTestTree}/. ./
      chmod -R u+w .
      patchShebangs scripts tests
      export PATH="${producerRuntimePath}:$PATH"

      bats --tap \
        tests/test-bootstrap-producer-config.bats \
        tests/test-bootstrap-producer-cluster.bats \
        tests/test-bootstrap-producer-idempotent.bats

      # T014: short chain DB - era-readiness predicate never holds.
      # phase_preflight runs header-extractor tip-info during the
      # polling loop and times out at rc=2 before any T019 phase fires.
      cp -rL ${shortSynthesizedChainDb}/chain-db $TMPDIR/short-chain-db
      chmod -R u+w $TMPDIR/short-chain-db
      BOOTSTRAP_PRODUCER_CHAIN_DB=$TMPDIR/short-chain-db \
        bats --tap tests/test-bootstrap-producer-chain.bats

      # T016: two real producers race against the same era-ready
      # chain DB and must converge on one complete bundle.
      cp -rL ${synthesizedChainDb}/chain-db $TMPDIR/chain-db
      chmod -R u+w $TMPDIR/chain-db
      BOOTSTRAP_PRODUCER_CHAIN_DB=$TMPDIR/chain-db \
        bats --tap tests/test-bootstrap-producer-concurrent.bats

      mkdir -p $out
    '';

  # T019b end-to-end: run the real producer pipeline against the
  # synthesized Conway-ready chain DB and assert that Amaru accepts the
  # resulting bundle. This is the regression check for the node-10.7.1
  # ledger-state projection in ledger-state-emitter.
  bootstrap-producer-synthesized =
    pkgs.runCommand "bootstrap-producer-synthesized"
      {
        nativeBuildInputs = [
          pkgs.bash
          pkgs.coreutils
          pkgs.findutils
          pkgs.gawk
          pkgs.jq
          amaruPkg
          headerExtractorPkgs.header-extractor
          headerExtractorPkgs.ledger-state-emitter
        ];
      } ''
      set -euo pipefail

      cp -rL ${synthesizedChainDb}/chain-db $TMPDIR/chain-db
      chmod -R u+w $TMPDIR/chain-db

      export PATH="${producerRuntimePath}:$PATH"
      AMARU_NETWORK=testnet_42 \
      AMARU_CLUSTER_READY_DEADLINE_SECONDS=10 \
      AMARU_WAIT_DEADLINE_SECONDS=10 \
      AMARU_POLL_INTERVAL_SECONDS=1 \
        ${pkgs.bash}/bin/bash ${../scripts/bootstrap-producer.sh} \
          $TMPDIR/chain-db \
          ${fixture}/configs/configs \
          $TMPDIR/bundle \
          testnet_42

      final=$TMPDIR/bundle/testnet_42
      test -d "$final/ledger.testnet_42.db"
      test -d "$final/chain.testnet_42.db"
      test -f "$final/nonces.json"
      test -n "$(find "$final/headers" -name 'header.*.cbor' -print -quit)"
      test -n "$(find "$final/snapshots" -name '*.cbor' -print -quit)"

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
