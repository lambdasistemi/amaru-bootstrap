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

  # ~4.6 epochs (testnet_42's epochLength = 86400). With the fixture's
  # 5% activeSlotsCoeff the resulting tip lands past 3*epochLength, so
  # the era-readiness predicate (which now anchors TARGET_SLOT at the
  # last slot of the latest *completed* epoch and requires
  # tip_epoch >= 3) holds for T016 + T019.
  synthesizedChainDb =
    mkSynthesizedChainDb "header-extractor-fixture-chain-db" 400000;

  synthesizedBootstrapBundle =
    pkgs.runCommand "bootstrap-producer-synthesized-bundle"
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
      mkdir -p $out

      export PATH="${producerRuntimePath}:$PATH"
      AMARU_NETWORK=testnet_42 \
      AMARU_CLUSTER_READY_DEADLINE_SECONDS=10 \
      AMARU_WAIT_DEADLINE_SECONDS=10 \
      AMARU_POLL_INTERVAL_SECONDS=1 \
        ${pkgs.bash}/bin/bash ${../scripts/bootstrap-producer.sh} \
          $TMPDIR/chain-db \
          ${fixture}/configs/configs \
          $out \
          testnet_42
    '';

  # ~50000 slots - well below 2 * epochLength. Tip exists but the
  # era-readiness predicate stays false, exercising the rc=2 branch
  # (T014).
  shortSynthesizedChainDb =
    mkSynthesizedChainDb "bootstrap-producer-fixture-short-chain-db" 50000;

  # Issue #29: deterministic short-epoch ChainDB corpus for the
  # Antithesis cold-start family. The observed cluster failure emitted
  # snapshots at slots 9, 129, and 249 with a 120-slot epoch. Stock
  # db-synthesizer rejects the exact Antithesis k/f tuple as too short
  # and, with sparse blocks, may leave no immutable tip to sample. This
  # corpus therefore keeps epochLength=120 but uses securityParam=8 and
  # activeSlotsCoeff=1.0 so the same early-slot window is dense enough
  # for immutable-DB based tools.
  antithesisShortEpochChainDb =
    pkgs.runCommand "antithesis-short-epoch-chain-db"
      {
        nativeBuildInputs = [
          pkgs.bash
          pkgs.coreutils
          pkgs.jq
          iogTools.db-synthesizer
        ];
      } ''
      set -euo pipefail

      fixture=${fixture}
      mkdir -p "$out/config" "$out/keys" "$out/chain-db"
      cp -rL "$fixture/configs/configs/." "$out/config/"
      cp -rL "$fixture/configs/keys/." "$out/keys/"
      chmod -R u+w "$out/config" "$out/keys"

      jq '
        .epochLength = 120
        | .securityParam = 8
        | .activeSlotsCoeff = 1.0
      ' "$out/config/shelley-genesis.json" \
        >"$out/config/shelley-genesis.json.tmp"
      mv "$out/config/shelley-genesis.json.tmp" \
        "$out/config/shelley-genesis.json"

      bulk="$TMPDIR/bulk-credentials.json"
      jq -n \
        --slurpfile opcert "$out/keys/opcert.cert" \
        --slurpfile vrf    "$out/keys/vrf.skey" \
        --slurpfile kes    "$out/keys/kes.skey" \
        '[[ $opcert[0], $vrf[0], $kes[0] ]]' \
        >"$bulk"

      db-synthesizer \
        --config "$out/config/config.json" \
        --bulk-credentials-file "$bulk" \
        -s 720 \
        --db "$out/chain-db" \
        -f

      printf '%s\n' \
        "# Antithesis short-epoch ChainDB corpus" \
        "" \
        "- source fixture: specs/001-snapshot-format-smoke/fixtures/p1-config" \
        "- epochLength: 120 slots" \
        "- securityParam: 8" \
        "- activeSlotsCoeff: 1.0" \
        "- synthesized slots: 720" \
        "- sampled ledger-state slots: 9, 129, 249" \
        "" \
        "The exact Antithesis profile uses a sparser active slot coefficient." \
        "This generated profile keeps the observed short epoch and snapshot" \
        "slot window while forcing enough blocks for immutable-DB sampling." \
        >"$out/METADATA.md"
    '';

  antithesisShortEpochSamples =
    pkgs.runCommand "antithesis-short-epoch-golden-samples"
      {
        nativeBuildInputs = [
          pkgs.bash
          pkgs.coreutils
          pkgs.findutils
          pkgs.jq
          amaruPkg
          headerExtractorPkgs.ledger-state-emitter
        ];
      } ''
      set -euo pipefail

      mkdir -p "$out/legacy" "$out/snapshots"
      cp ${antithesisShortEpochChainDb}/METADATA.md "$out/METADATA.md"
      cp -rL ${antithesisShortEpochChainDb}/chain-db "$TMPDIR/chain-db"
      cp -rL ${antithesisShortEpochChainDb}/config "$TMPDIR/config"
      chmod -R u+w "$TMPDIR/chain-db" "$TMPDIR/config"

      for slot in 9 129 249; do
        ledger-state-emitter \
          --db "$TMPDIR/chain-db" \
          --config "$TMPDIR/config/config.json" \
          --target-slot "$slot" \
          --out "$out/legacy/$slot.cbor"

        amaru convert-ledger-state \
          --network testnet_42 \
          --snapshot "$out/legacy/$slot.cbor" \
          --target-dir "$out/snapshots"
      done

      epoch_length=$(jq -r '.epochLength' \
        "$TMPDIR/config/shelley-genesis.json")
      for history in "$out"/snapshots/history.*.json; do
        tmp="$history.tmp"
        jq --argjson epochLength "$epoch_length" \
          '(.eras[] | select(.end == null) | .params.epoch_size_slots) = $epochLength' \
          "$history" >"$tmp"
        mv "$tmp" "$history"
      done

      cbor_count=$(find "$out/snapshots" -maxdepth 1 \
        -name '*.cbor' | wc -l)
      if [ "$cbor_count" -ne 3 ]; then
        echo "expected 3 converted short-epoch snapshots, got $cbor_count" >&2
        exit 1
      fi
    '';
in
{
  amaru = amaruPkg;
  db-synthesizer = iogTools.db-synthesizer;
  db-analyser = iogTools.db-analyser;
  snapshot-converter = iogTools.snapshot-converter;
  header-extractor = headerExtractorPkgs.header-extractor;
  ledger-state-emitter = headerExtractorPkgs.ledger-state-emitter;
  bootstrap-producer-image = bootstrapProducerImage;
  antithesis-short-epoch-samples = antithesisShortEpochSamples;

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

      bats --tap tests/test-bootstrap-producer-history.bats

      mkdir -p $out
    '';

  # T019b end-to-end: assert the real producer pipeline, run in
  # synthesizedBootstrapBundle above, leaves the canonical Amaru bundle
  # layout. This is the regression check for the node-10.7.1
  # ledger-state projection in ledger-state-emitter.
  bootstrap-producer-synthesized =
    pkgs.runCommand "bootstrap-producer-synthesized"
      {
        nativeBuildInputs = [
          pkgs.bash
          pkgs.coreutils
          pkgs.findutils
        ];
      } ''
      set -euo pipefail

      final=${synthesizedBootstrapBundle}/testnet_42
      test -d "$final/ledger.testnet_42.db"
      test -d "$final/chain.testnet_42.db"
      test -f "$final/nonces.json"
      test -n "$(find "$final/snapshots" -name '*.cbor' -print -quit)"
      header_count=$(find "$final/headers" -name 'header.*.cbor' | wc -l)
      if [ "$header_count" -lt 4 ]; then
        echo "expected at least 4 imported headers, found $header_count" >&2
        exit 1
      fi
      test -d "$final/ledger.testnet_42.db/live"
      snapshot_count=0
      for d in "$final"/ledger.testnet_42.db/*; do
        if [ -d "$d" ] && [[ "$(basename "$d")" =~ ^[0-9]+$ ]]; then
          snapshot_count=$(( snapshot_count + 1 ))
        fi
      done
      if [ "$snapshot_count" -lt 3 ]; then
        echo "expected at least 3 historical ledger snapshots, found $snapshot_count" >&2
        exit 1
      fi

      mkdir -p $out
    '';

  # Prove that the produced bootstrap bundle is not only importable but
  # usable as Amaru startup state. The command is intentionally run
  # without a live upstream peer; success means Amaru opened the ledger
  # and chain stores, logged build_ledger, and stayed alive until the
  # timeout instead of failing during bootstrap.
  amaru-run-bootstrap =
    pkgs.runCommand "amaru-run-bootstrap"
      {
        nativeBuildInputs = [
          pkgs.bash
          pkgs.coreutils
          pkgs.gnugrep
          amaruPkg
        ];
      } ''
      set -euo pipefail

      cp -rL ${synthesizedBootstrapBundle}/testnet_42 $TMPDIR/testnet_42
      chmod -R u+w $TMPDIR/testnet_42

      log=$TMPDIR/amaru-run.log
      set +e
      timeout 30s amaru --with-json-traces run \
        --network testnet_42 \
        --ledger-dir $TMPDIR/testnet_42/ledger.testnet_42.db \
        --chain-dir $TMPDIR/testnet_42/chain.testnet_42.db \
        --listen-address 127.0.0.1:0 \
        --peer-address 127.0.0.1:9 \
        >"$log" 2>&1
      rc=$?
      set -e

      cat "$log"
      if [ "$rc" -ne 124 ]; then
        echo "expected amaru run to stay alive until timeout, got rc=$rc" >&2
        exit 1
      fi
      if grep -q 'Failed to create ledger' "$log"; then
        echo "amaru failed to create the bootstrapped ledger" >&2
        exit 1
      fi
      if grep -q 'ledger tip header not found' "$log"; then
        echo "amaru opened the ledger but could not align the chain store" >&2
        exit 1
      fi
      if ! grep -q 'build_ledger' "$log"; then
        echo "amaru did not reach ledger startup from the bootstrap bundle" >&2
        exit 1
      fi

      mkdir -p $out
    '';

  # Issue #29 regression gate. This intentionally exercises the exact
  # failure boundary seen in the Antithesis short-epoch experiment:
  # convert succeeds, then `amaru import-ledger-state` must be able to
  # consume the generated snapshots. On the current projection this
  # fails with "unexpected type map at position 2: expected u32".
  antithesis-short-epoch-golden =
    pkgs.runCommand "antithesis-short-epoch-golden"
      {
        nativeBuildInputs = [
          pkgs.bash
          pkgs.coreutils
          amaruPkg
        ];
      } ''
      set -euo pipefail

      ledger_dir="$TMPDIR/ledger.testnet_42.db"
      mkdir -p "$ledger_dir"

      amaru import-ledger-state \
        --network testnet_42 \
        --ledger-dir "$ledger_dir" \
        --snapshot-dir ${antithesisShortEpochSamples}/snapshots

      test -d "$ledger_dir/live"
      mkdir -p "$out"
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
