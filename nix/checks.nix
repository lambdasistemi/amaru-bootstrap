{ pkgs
, amaruPkg
, iogTools
, bootstrapProducerImage
, peerSnapshotNegativePackages
}:

# Flake checks: a derivation per artefact. Each test check builds a
# minimal `bats-runner` source tree at evaluation time using
# pkgs.linkFarm so paths inside the sandbox resolve identically to a
# local checkout (`./scripts`, `./tests`, `./specs/.../fixtures`). This
# avoids surprising path-resolution bugs that came from manually
# stitching files into a runCommand output.
let
  cliMockTestTree = pkgs.linkFarm "cli-mock-test-tree" [
    { name = "tests"; path = ../tests; }
  ];

  producerRuntimePath = pkgs.lib.makeBinPath [
    pkgs.bash
    pkgs.coreutils
    pkgs.findutils
    pkgs.gawk
    pkgs.jq
    amaruPkg
    iogTools.db-analyser
  ];

  # T012-T016: bats sees the orchestrator script + fixtures + tests/.
  bootstrapProducerTestTree = pkgs.linkFarm "bootstrap-producer-test-tree" [
    { name = "scripts/bootstrap-producer.sh"; path = ../scripts/bootstrap-producer.sh; }
    { name = "scripts/amaru-relay-bootstrap.sh"; path = ../scripts/amaru-relay-bootstrap.sh; }
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
    mkSynthesizedChainDb "bootstrap-producer-fixture-chain-db" 400000;

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
          pkgs.cacert
        ];
      } ''
      set -euo pipefail

      # amaru snapshot create builds a reqwest (Koios) client unconditionally,
      # which needs a CA trust anchor even on the offline --snapshot path.
      export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt

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
        -s 3000 \
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

  # Short-epoch (epochLength=120) bootstrap bundle, produced by the same
  # upstream-bootstrap pipeline as the standard path. Exercises
  # create-snapshots + bootstrap against a short-epoch chain and is the
  # consume-side fixture for the antithesis golden gate.
  shortEpochBootstrapBundle =
    pkgs.runCommand "antithesis-short-epoch-bundle"
      {
        nativeBuildInputs = [
          pkgs.bash
          pkgs.coreutils
          pkgs.findutils
          pkgs.gawk
          pkgs.jq
          amaruPkg
          iogTools.db-analyser
          pkgs.cacert
        ];
      } ''
      set -euo pipefail

      # amaru snapshot create builds a reqwest (Koios) client unconditionally,
      # which needs a CA trust anchor even on the offline --snapshot path.
      export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt

      cp -rL ${antithesisShortEpochChainDb}/chain-db "$TMPDIR/chain-db"
      cp -rL ${antithesisShortEpochChainDb}/config "$TMPDIR/config"
      chmod -R u+w "$TMPDIR/chain-db" "$TMPDIR/config"
      mkdir -p "$out"

      export PATH="${producerRuntimePath}:$PATH"
      AMARU_NETWORK=testnet_42 \
      AMARU_CLUSTER_READY_DEADLINE_SECONDS=10 \
      AMARU_WAIT_DEADLINE_SECONDS=10 \
      AMARU_POLL_INTERVAL_SECONDS=1 \
        ${pkgs.bash}/bin/bash ${../scripts/bootstrap-producer.sh} \
          "$TMPDIR/chain-db" \
          "$TMPDIR/config" \
          "$out" \
          testnet_42
    '';
in
{
  amaru = amaruPkg;
  db-synthesizer = iogTools.db-synthesizer;
  db-analyser = iogTools.db-analyser;
  snapshot-converter = iogTools.snapshot-converter;
  bootstrap-producer-image = bootstrapProducerImage;
  peer-snapshot-negative-control = pkgs.linkFarm
    "peer-snapshot-negative-control"
    (pkgs.lib.mapAttrsToList (fault: package: {
      name = fault;
      path = pkgs.testers.testBuildFailure' {
        drv = package;
        expectedBuilderLogEntries = {
          missing-mainnet = [
            "peer-snapshot validation failed: mainnet: missing staged file"
          ];
          invalid-schema-preprod = [
            "peer-snapshot validation failed: preprod: schema violation"
          ];
          wrong-magic-preview = [
            "peer-snapshot validation failed: preview: expected NetworkMagic 2"
          ];
          empty-pools-mainnet = [
            "peer-snapshot validation failed: mainnet: bigLedgerPools is empty"
          ];
        }.${fault};
      };
    }) peerSnapshotNegativePackages);
  antithesis-short-epoch-samples =
    pkgs.runCommand "antithesis-short-epoch-samples"
      {
        nativeBuildInputs = [ pkgs.coreutils pkgs.findutils ];
      } ''
      set -euo pipefail
      bundle=${shortEpochBootstrapBundle}/testnet_42
      # The short-epoch producer materialized at least three snapshot dirs
      # and the era-history override for consume.
      snap_count=$(find "$bundle/snapshots/testnet_42" -mindepth 1 -maxdepth 1 -type d \
        -regextype posix-extended -regex '.*/[0-9]+\.[0-9a-f]+' | wc -l)
      if [ "$snap_count" -lt 3 ]; then
        echo "expected >=3 short-epoch snapshot dirs, found $snap_count" >&2
        exit 1
      fi
      test -f "$bundle/era-history.json"
      mkdir -p $out
    '';

  shellcheck = pkgs.runCommand "shellcheck"
    {
      nativeBuildInputs = [ pkgs.shellcheck ];
    } ''
    shellcheck -s bash -e SC1091 ${../scripts/bootstrap-producer.sh}
    shellcheck -s bash -e SC1091 ${../scripts/amaru-relay-bootstrap.sh}
    mkdir -p $out
  '';

  # Issue #51: validate declared mock surfaces against real binaries
  # and confirm guard coverage in every audited bats owner.
  cli-mock-honesty =
    pkgs.runCommand "cli-mock-honesty"
      {
        nativeBuildInputs = [
          pkgs.bash
          pkgs.coreutils
          pkgs.gnugrep
          amaruPkg
        ];
      } ''
      set -euo pipefail
      cp -rL ${cliMockTestTree}/. ./
      chmod -R u+w .
      patchShebangs tests
      bash tests/check-cli-mock-honesty.sh
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
          pkgs.cacert
          pkgs.coreutils
          pkgs.jq
        ];
      } ''
      set -euo pipefail
      cp -rL ${bootstrapProducerTestTree}/. ./
      chmod -R u+w .
      patchShebangs scripts tests
      export PATH="${producerRuntimePath}:$PATH"
      # The suites that drive the REAL amaru (concurrent, chain) need a CA
      # anchor: `amaru snapshot create` builds a reqwest client at startup
      # even on the offline --cardano-node-db/--snapshot path, and panics
      # with "No CA certificates were loaded" without one.
      export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt

      bats --tap \
        tests/test-amaru-relay-bootstrap.bats \
        tests/test-bootstrap-helpers.bats \
        tests/test-bootstrap-producer-canonical-cli.bats \
        tests/test-bootstrap-producer-sparse-boundaries.bats \
        tests/test-bootstrap-producer-config.bats \
        tests/test-bootstrap-producer-cluster.bats \
        tests/test-bootstrap-producer-idempotent.bats

      # T014: short chain DB - era-readiness predicate never holds.
      # phase_preflight runs db-analyser tip poll during the
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
  # ledger-state projection.
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
      # nonces + bootstrap headers are baked into chain.<net>.db by
      # `amaru bootstrap`; the bundle ships the era-history override for
      # `amaru run --era-history` at consume time.
      test -f "$final/era-history.json"
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

  # Issue #52 slice 1 (T005): exact six-point proof. Runs the production
  # parser path (the producer above writes .logs/targets.json from one
  # db-analyser --show-slot-block-no pass over the real synthesized chain
  # DB) and asserts all three target points and all three parent points
  # from research.md. The SAME assertion is then run against an empty
  # array and required to fail, so a vacuous parser that accepts zero
  # records cannot pass this check.
  db-analyser-points =
    pkgs.runCommand "db-analyser-points"
      {
        nativeBuildInputs = [
          pkgs.bash
          pkgs.coreutils
          pkgs.jq
        ];
      } ''
      set -euo pipefail

      targets=${synthesizedBootstrapBundle}/.logs/targets.json
      expected='[
        {"epoch":1,"slot":172731,"hash":"e1fb2a7b5a5b01d9b2cb5f2a5b8e2559b6929c695abf7e523e3b3cf6d4c02278","parent_point":"172652.3420432a02ae631e3b3cfd2dcbac97b415144764bcb554b074092b9b2bbb9352"},
        {"epoch":2,"slot":259176,"hash":"dddf69466f866b9898024502f99efb0ed73daa65a2543c0e9c413f078318345e","parent_point":"259173.e945d6beed5f99be2f618e43d1fe063941ed9d2466fdae18e9345a8137f24ee8"},
        {"epoch":3,"slot":345164,"hash":"3102adf971aecbc9d47c12e3cf8b883c53b55f61ef19b5d377c91e9bd4c68342","parent_point":"345159.19fa713646ce859bc47756c47af2a04cb28cef4944331ef70be2f999883e881d"}
      ]'

      assert_points() {
        jq -e --argjson expected "$expected" '
          ( [ .[] | {epoch, slot, hash, parent_point} ] == $expected )
          and
          ( [ .[] | keys ] | all(. == ["epoch","hash","parent_point","slot"]) )
        ' "$1"
      }

      if [ ! -s "$targets" ]; then
        echo "db-analyser-points: production .logs/targets.json missing or empty: $targets" >&2
        exit 1
      fi

      if ! assert_points "$targets"; then
        echo "db-analyser-points: production targets.json does not match the six frozen points" >&2
        echo "--- actual ---" >&2
        cat "$targets" >&2
        exit 1
      fi
      echo "db-analyser-points: all six frozen points match production targets.json"

      printf '[]\n' > "$TMPDIR/empty.json"
      set +e
      assert_points "$TMPDIR/empty.json" 2>/dev/null
      ctrl_rc=$?
      set -e
      if [ "$ctrl_rc" -ne 1 ]; then
        echo "db-analyser-points: NEGATIVE CONTROL FAILED - empty array assertion exited $ctrl_rc (want exactly 1)" >&2
        exit 1
      fi
      echo "db-analyser-points: negative control OK - empty array rejected (assertion exit=$ctrl_rc)"

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

      # amaru node run builds a reqwest client at startup; needs a CA anchor.
      export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt

      cp -rL ${synthesizedBootstrapBundle}/testnet_42 $TMPDIR/testnet_42
      chmod -R u+w $TMPDIR/testnet_42

      log=$TMPDIR/amaru-run.log
      set +e
      timeout 30s amaru --with-json-traces node run \
        --network testnet_42 \
        --era-history $TMPDIR/testnet_42/era-history.json \
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

  # Issue #29 regression gate. Exercises the Antithesis short-epoch
  # (epochLength=120) boundary end-to-end: the producer builds a bundle
  # via create-snapshots + bootstrap, then `amaru run` must open it and
  # stay alive. The custom epoch length is supplied at runtime via
  # --era-history (the network built-in is 86400), so this is the
  # gate for the runtime-testnet-parameters + short-epoch ledger fixes.
  antithesis-short-epoch-golden =
    pkgs.runCommand "antithesis-short-epoch-golden"
      {
        nativeBuildInputs = [
          pkgs.bash
          pkgs.coreutils
          pkgs.gnugrep
          amaruPkg
        ];
      } ''
      set -euo pipefail

      # amaru node run builds a reqwest client at startup; needs a CA anchor.
      export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt

      cp -rL ${shortEpochBootstrapBundle}/testnet_42 $TMPDIR/testnet_42
      chmod -R u+w $TMPDIR/testnet_42

      log=$TMPDIR/amaru-run.log
      set +e
      timeout 30s amaru --with-json-traces node run \
        --network testnet_42 \
        --era-history $TMPDIR/testnet_42/era-history.json \
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
        echo "amaru failed to create the short-epoch ledger" >&2
        exit 1
      fi
      if ! grep -q 'build_ledger' "$log"; then
        echo "amaru did not reach ledger startup from the short-epoch bundle" >&2
        exit 1
      fi

      mkdir -p "$out"
    '';

}
