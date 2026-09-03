{ pkgs
, amaruPkg
, iogTools
, bootstrapProducerImage
, peerSnapshotNegativePackages
, amaruRev
, cardano-configurations
, cardanoConfigurationsRev
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
    # Hosted cli-mock-honesty must see carried patch artifacts so the
    # range-whitespace property executes (I-095-AUDIT).
    { name = "nix/patches"; path = ../nix/patches; }
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

  # Issue 95: the local-first bootstrap decision, proved by behavioural Rust
  # fixtures inside the patched amaru-bootstrap crate that drive production's own
  # functions. Each named mutant must make those fixtures fail for a named
  # reason, so the property is re-proved able to fail on every run. A mutation
  # whose edit does not change the source fails its own derivation, and a
  # mutant that merely failed to compile is rejected, so neither can be
  # reported as killed.
  # Apply `sed` to one file in the patched Amaru tree. The edit must
  # change production and must not change the `#[cfg(test)]` module: a
  # kill attributable only to a fixture replica is not evidence (F-001).
  # Files with no test module treat the whole file as production.
  applyProductionOnlySed = { name, sed, file }:
    pkgs.runCommand "amaru-mutant-${name}-src" { } ''
      set -euo pipefail
      cp -r ${amaruPkg.patchedSource} $out
      chmod -R u+w $out
      target=$out/${file}
      if [ ! -f "$target" ]; then
        echo "mutation ${name}: missing $target" >&2
        exit 1
      fi
      hash_region() {
        if grep -q '^#\[cfg(test)\]$' "$target"; then
          case "$1" in
            prod) sed '/^#\[cfg(test)\]$/,$d' "$target" ;;
            tests) sed -n '/^#\[cfg(test)\]$/,$p' "$target" ;;
          esac | sha256sum | cut -d' ' -f1
        else
          case "$1" in
            prod) sha256sum "$target" | cut -d' ' -f1 ;;
            tests) printf 'none\n' ;;
          esac
        fi
      }
      prod_before=$(hash_region prod)
      tests_before=$(hash_region tests)
      before=$(sha256sum "$target" | cut -d' ' -f1)
      sed -i ${pkgs.lib.escapeShellArg sed} "$target"
      after=$(sha256sum "$target" | cut -d' ' -f1)
      if [ "$before" = "$after" ]; then
        echo "mutation ${name} did not apply; it would test nothing" >&2
        exit 1
      fi
      prod_after=$(hash_region prod)
      tests_after=$(hash_region tests)
      if [ "$prod_before" = "$prod_after" ]; then
        echo "mutation ${name} did not edit production; the kill would not be attributable to production" >&2
        exit 1
      fi
      if [ "$tests_before" != "$tests_after" ]; then
        echo "mutation ${name} edited the test module; the kill would not be attributable to production" >&2
        exit 1
      fi
    '';

  localFirstTest = { name, src }: amaruPkg.localFirstTest {
    inherit name src;
    doCheck = true;
    cargoTestExtraArgs = "--package amaru-bootstrap --lib bootstrap::tests::local_first";
  };

  localFirstFixtures = localFirstTest {
    name = "amaru-local-first-fixtures";
    src = amaruPkg.patchedSource;
  };

  localFirstFile = "crates/amaru-bootstrap/src/bootstrap/mod.rs";

  # F-001 seed: the pre-repair two-site download sed. It must keep editing
  # the test module on this tree, so the production-only guard is shown able
  # to fire rather than sitting over an empty trap.
  twoSiteDownloadSed =
    ''/^\s*download_snapshots(.*\.await?;/d;/^\s*download_snapshots(/,/\.await/d'';

  testModuleEditRejected =
    pkgs.runCommand "local-first-test-module-edit-rejected" { } ''
      set -euo pipefail
      cp -r ${amaruPkg.patchedSource} work
      chmod -R u+w work
      target=work/${localFirstFile}
      tests_before=$(sed -n '/^#\[cfg(test)\]$/,$p' "$target" | sha256sum | cut -d' ' -f1)
      sed -i ${pkgs.lib.escapeShellArg twoSiteDownloadSed} "$target"
      tests_after=$(sed -n '/^#\[cfg(test)\]$/,$p' "$target" | sha256sum | cut -d' ' -f1)
      if [ "$tests_before" = "$tests_after" ]; then
        echo "control: two-site download sed did not edit the test module; the production-only guard cannot be shown to fire" >&2
        exit 1
      fi
      echo "control: two-site download sed edits the test module" >"$out"
    '';

  localFirstMutants = map
    (mutant: mutant // {
      failure = pkgs.testers.testBuildFailure (localFirstTest {
        name = "amaru-local-first-${mutant.name}";
        src = applyProductionOnlySed {
          inherit (mutant) name sed;
          file = mutant.file or localFirstFile;
        };
      });
    })
    # Every pattern is anchored to a contiguous substring that rustfmt keeps on
    # one physical line (a call or statement under the crate's max_width), or
    # captures the leading indentation instead of pinning it, or is a range
    # that survives the call being reflowed. A pattern matched only by luck of
    # the current formatting is how production-owner-disconnect went vacuous
    # when the rebase reformatted its call site.
    # F-001 class: applyProductionOnlySed requires each pattern to change
    # production and leave the test module untouched, so a fixture replica
    # of a production call cannot author the kill. Combined with the named
    # test having to fail, the kill is attributable to a production site on
    # that test's path.
    [
      # DIFFERENT-SNAPSHOT-SET, carried: the selector runs, but not over the disk collection.
      { name = "different-snapshot-set"; test = "exact_local_window_skips_the_remote_index";
        reason = "an exact local window must not reach the remote index";
        sed = ''s@select_bootstrap_snapshots(local, Some(target_epoch))@select_bootstrap_snapshots(\&[], Some(target_epoch))@''; }
      # Same class, complete substitute: only member identity tells the two apart.
      { name = "foreign-snapshot-set"; test = "exact_local_window_skips_the_remote_index";
        reason = "local success must be supplied from the discovered local collection itself";
        sed = ''s@^\(\s*\)match select_bootstrap_snapshots(local, Some(target_epoch)) {@\1let foreign: Vec<Snapshot> = local.iter().map(|s| Snapshot { epoch: s.epoch, point: s.point.clone(), key: format!("foreign/{}", s.key) }).collect();\n\1match select_bootstrap_snapshots(\&foreign, Some(target_epoch)) {@''; }
      # SAME-LINE-SECOND-EARLY-RETURN, carried, in the frozen shape: close the guarded
      # branch and open a second success exit on that same physical line.
      { name = "same-line-second-early-return"; test = "insufficient_local_collections_consult_the_remote_index";
        reason = "wrong target: must consult the remote index";
        sed = ''s@^\(\s*\)return Ok(selected\.to_vec());@\1return Ok(selected.to_vec()); }\1if snapshots.len() >= 3 {\1return Ok(vec![snapshots[0].clone(), snapshots[1].clone(), snapshots[2].clone()]);@''; }
      # The production decision owner stops being told the exact local window:
      # with None it defers even when the local collection satisfies the
      # request, so production goes remote to ask for what it already had.
      { name = "production-owner-disconnect"; test = "production_owner_uses_the_exact_local_window";
        reason = "production must satisfy an exact local window without the remote index";
        sed = ''s@decide_local_first(\&snapshots, target_epoch)@decide_local_first(\&snapshots, None)@''; }
      # Skip every archive inside production's download_snapshots. Unique
      # to that function's body (the fixtures call the function; they do
      # not contain this predicate), so the named test's kill is the
      # production seam, not a fixture replica of the call.
      { name = "production-download-disconnect"; test = "remotely_listed_snapshots_reach_the_download_seam";
        reason = "a remotely listed snapshot must reach the download seam";
        sed = ''s@if !should_download_snapshot(snapshots_dir, snapshot) {@if true { continue; } if !should_download_snapshot(snapshots_dir, snapshot) {@''; }
    ];

  tvarFile = "crates/amaru-bootstrap/src/cardano_node/tvar.rs";

  # F-002: disable the remaining-entry count that runs before datatype().
  # A complete definite-length map then hits EOF at datatype() and import
  # fails as end_of_input; the truncated corpus case does not discriminate.
  tvarSizeBeforeDatatypeSed =
    ''s@if size.is_some_and(|len| actual_size + chunk_size >= len) {@if false \&\& size.is_some_and(|len| actual_size + chunk_size >= len) {@'';

  tvarSizeBeforeDatatypeSrc = applyProductionOnlySed {
    name = "tvar-size-before-datatype";
    file = tvarFile;
    sed = tvarSizeBeforeDatatypeSed;
  };

  tvarSizeBeforeDatatypeAmaru = amaruPkg.buildPackageFromSrc {
    name = "amaru-tvar-size-before-datatype";
    src = tvarSizeBeforeDatatypeSrc;
  };

  tvarSizeBeforeDatatypeFailure =
    pkgs.testers.testBuildFailure (pkgs.runCommand "tvar-size-before-datatype-complete-import"
      {
        nativeBuildInputs = [
          pkgs.bash
          pkgs.coreutils
          pkgs.gnugrep
          pkgs.gnutar
          pkgs.jq
          pkgs.python3
          pkgs.zstd
          tvarSizeBeforeDatatypeAmaru
        ];
      } ''
      set -euo pipefail
      export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
      export AMARU_GLOBAL_CONSENSUS_SECURITY_PARAM=8
      export AMARU_GLOBAL_ACTIVE_SLOT_COEFF_INVERSE=1
      export AMARU_GLOBAL_EPOCH_LENGTH_SCALE_FACTOR=15
      cp -rL ${shortEpochBootstrapBundle}/testnet_42 $TMPDIR/testnet_42
      chmod -R u+w $TMPDIR/testnet_42
      tests=${../tests}
      bash "$tests/check-short-epoch-tvar-decode.sh" $TMPDIR/testnet_42
      echo "complete definite-length map imported without the size-before-datatype guard" >&2
      exit 0
    '');
in
{

  amaru-local-first-semantic =
    pkgs.runCommand "amaru-local-first-semantic"
      { nativeBuildInputs = [ pkgs.gnugrep ]; } ''
      set -euo pipefail
      echo "fixtures green on the patched source: ${localFirstFixtures}"
      echo "mutant count: ${toString (builtins.length localFirstMutants)}"
      [ ${toString (builtins.length localFirstMutants)} -ge 1 ]
      echo "test-module-edit control: ${testModuleEditRejected}"
      ${pkgs.lib.concatMapStrings (mutant: ''
        log=${mutant.failure}/testBuildFailure.log
        grep -q 'test result: FAILED' "$log" || {
          echo "mutant ${mutant.name}: build failed without a test failure" >&2
          exit 1
        }
        grep -q '${mutant.test} ... FAILED' "$log" || {
          echo "mutant ${mutant.name}: expected ${mutant.test} to fail" >&2
          exit 1
        }
        grep -qF ${pkgs.lib.escapeShellArg mutant.reason} "$log" || {
          echo "mutant ${mutant.name}: killed for the wrong reason" >&2
          exit 1
        }
        echo "mutant ${mutant.name}: killed by ${mutant.test}"
      '') localFirstMutants}
      mkdir -p $out
    '';
  # I-088-CHECK: execute the packaged version surface. A package-only
  # alias would keep `nix flake check` green without observing identity.
  amaru = pkgs.runCommand "amaru-git-identity"
    {
      nativeBuildInputs = [
        pkgs.bash
        pkgs.coreutils
        pkgs.gnugrep
        amaruPkg
      ];
    } ''
      set -euo pipefail

      expected_short='${builtins.substring 0 8 amaruRev}'
      mismatch_short='ffffffff'
      if [ "''${#expected_short}" -ne 8 ]; then
        echo "amaru git identity: expected short revision is not 8 characters: $expected_short" >&2
        exit 1
      fi
      if [ "$expected_short" = "$mismatch_short" ]; then
        echo "amaru git identity: mismatch token collided with locked short revision" >&2
        exit 1
      fi

      assert_version_identity() {
        local output=$1
        local expected=$2
        printf '%s\n' "$output" | grep -F -- "$expected" >/dev/null || return 1
        printf '%s\n' "$output" | grep -Fi -- 'dirty' >/dev/null && return 1
        return 0
      }

      version=$(amaru --version 2>&1)
      printf 'amaru --version: %s\n' "$version"
      if [ -z "$version" ]; then
        echo "amaru git identity: empty --version output" >&2
        exit 1
      fi

      if ! assert_version_identity "$version" "$expected_short"; then
        echo "amaru git identity: version output missing locked short revision $expected_short or reports dirty" >&2
        echo "  output: $version" >&2
        exit 1
      fi
      echo "amaru git identity: positive control OK ($expected_short, clean)"

      if printf '%s\n' "$version" | grep -F -- "$mismatch_short" >/dev/null; then
        echo "amaru git identity: observed version contains mismatch token $mismatch_short" >&2
        exit 1
      fi
      set +e
      assert_version_identity "$version" "$mismatch_short"
      mismatch_rc=$?
      set -e
      if [ "$mismatch_rc" -eq 0 ]; then
        echo "amaru git identity: NEGATIVE CONTROL FAILED - mismatch $mismatch_short accepted" >&2
        exit 1
      fi
      echo "amaru git identity: mismatch negative control OK (rc=$mismatch_rc)"

      dirty_output="$version+dirty"
      set +e
      assert_version_identity "$dirty_output" "$expected_short"
      dirty_rc=$?
      set -e
      if [ "$dirty_rc" -eq 0 ]; then
        echo "amaru git identity: NEGATIVE CONTROL FAILED - dirty marker accepted" >&2
        exit 1
      fi
      echo "amaru git identity: dirty negative control OK (rc=$dirty_rc)"

      mkdir -p "$out"
    '';
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
          tampered-staged-mainnet = [
            "peer-snapshot validation failed: mainnet: sha256 does not match anchored record"
          ];
        }.${fault};
      };
    }) peerSnapshotNegativePackages);
  peer-snapshot-anchor = pkgs.runCommand "peer-snapshot-anchor"
    {
      nativeBuildInputs = [ pkgs.bash pkgs.coreutils pkgs.jq ];
    } ''
    set -euo pipefail
    bash ${./peer-snapshots/anchor.sh} \
      ${./peer-snapshots/resolution.json} \
      ${cardano-configurations} \
      '${amaruRev}' \
      '${cardanoConfigurationsRev}'
    mkdir -p $out
  '';

  # I3 negative control for the anchor itself. The anchored record is only
  # evidence if a doctored record is rejected, so every mutation below must
  # make the SAME assertions (nix/peer-snapshots/anchor.sh) fail. Without
  # this, a future edit that drops, say, the key-set assertion would keep
  # peer-snapshot-anchor green and silently stop enforcing D4.
  peer-snapshot-anchor-negative-control = pkgs.runCommand
    "peer-snapshot-anchor-negative-control"
    {
      nativeBuildInputs = [ pkgs.bash pkgs.coreutils pkgs.jq ];
    } ''
    set -euo pipefail
    anchor=${./peer-snapshots/anchor.sh}
    record=${./peer-snapshots/resolution.json}
    amaru_rev='${amaruRev}'
    configs_rev='${cardanoConfigurationsRev}'

    # A minimal stand-in for the pinned configs input, so the byte side can
    # be mutated too (the store path itself is read-only).
    inputs=$TMPDIR/inputs
    for network in mainnet preprod preview; do
      install -D -m 0644 \
        ${cardano-configurations}/network/$network/cardano-node/peer-snapshot.json \
        "$inputs/network/$network/cardano-node/peer-snapshot.json"
    done

    run_anchor() { # run_anchor <record> <inputs-root>
      bash "$anchor" "$1" "$2" "$amaru_rev" "$configs_rev"
    }

    if ! run_anchor "$record" "$inputs" >/dev/null; then
      echo "anchor negative control: the unmutated record is already RED" >&2
      exit 1
    fi
    echo "anchor negative control: baseline GREEN"

    mutations=(
      'mainnet-sha256-flipped:.snapshots.mainnet.sha256 |= (.[0:63] + (if .[63:64] == "a" then "b" else "a" end))'
      'preprod-sha256-flipped:.snapshots.preprod.sha256 |= (.[0:63] + (if .[63:64] == "a" then "b" else "a" end))'
      'preview-sha256-flipped:.snapshots.preview.sha256 |= (.[0:63] + (if .[63:64] == "a" then "b" else "a" end))'
      'amaru-rev-flipped:.amaru_rev |= (.[0:39] + (if .[39:40] == "a" then "b" else "a" end))'
      'configs-rev-flipped:.configs_rev |= (.[0:39] + (if .[39:40] == "a" then "b" else "a" end))'
      'query-url-dropped:del(.query_url)'
      'query-url-emptied:.query_url = ""'
      'resolved-at-dropped:del(.resolved_at_utc)'
      'committer-date-malformed:.amaru_committer_date_utc = "2026-07-29 07:56:00"'
      'preview-network-dropped:del(.snapshots.preview)'
      'extra-network-added:.snapshots.sanchonet = {sha256: .snapshots.mainnet.sha256}'
      'sha256-uppercased:.snapshots.mainnet.sha256 |= ascii_upcase'
      'sha256-truncated:.snapshots.preprod.sha256 |= .[0:63]'
      'record-emptied:{}'
    )

    survived=0
    for entry in "''${mutations[@]}"; do
      name=''${entry%%:*}
      program=''${entry#*:}
      jq "$program" "$record" >"$TMPDIR/$name.json"
      if run_anchor "$TMPDIR/$name.json" "$inputs" >/dev/null 2>&1; then
        echo "anchor negative control: mutant SURVIVED: $name" >&2
        survived=$((survived + 1))
      else
        echo "anchor negative control: mutant killed: $name"
      fi
    done

    # Byte side: the record is untouched, one staged input byte changes.
    chmod -R u+w "$inputs"
    printf '\n' \
      >>"$inputs/network/mainnet/cardano-node/peer-snapshot.json"
    if run_anchor "$record" "$inputs" >/dev/null 2>&1; then
      echo "anchor negative control: mutant SURVIVED: mainnet-input-byte-appended" >&2
      survived=$((survived + 1))
    else
      echo "anchor negative control: mutant killed: mainnet-input-byte-appended"
    fi

    if [ "$survived" -ne 0 ]; then
      echo "anchor negative control: $survived mutant(s) survived; the anchor does not distinguish a correct record from a doctored one" >&2
      exit 1
    fi
    mkdir -p $out
  '';
  antithesis-short-epoch-samples =
    pkgs.runCommand "antithesis-short-epoch-samples"
      {
        nativeBuildInputs = [
          pkgs.coreutils
          pkgs.findutils
          pkgs.gnused
        ];
      } ''
      set -euo pipefail
      bundle=${shortEpochBootstrapBundle}/testnet_42
      # The short-epoch producer materialized at least three snapshot
      # artifacts (directory or matching .tar.zst) and era-history.
      snap_count=$(
        find "$bundle/snapshots/testnet_42" -mindepth 1 -maxdepth 1 \
          -regextype posix-extended \( \
            -type d -regex '.*/[0-9]+\.[0-9a-f]+' -o \
            -type f -regex '.*/[0-9]+\.[0-9a-f]+\.tar\.zst' \
          \) -printf '%f\n' \
        | sed 's/\.tar\.zst$//' \
        | sort -u \
        | wc -l
      )
      if [ "$snap_count" -lt 3 ]; then
        echo "expected >=3 short-epoch snapshot artifacts, found $snap_count" >&2
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
    shellcheck -s bash ${../scripts/resolve-peer-snapshots}
    shellcheck -s bash ${./peer-snapshots/anchor.sh}
    shellcheck -s bash ${../tests/check-short-epoch-utxo-set.sh}
    shellcheck -s bash ${../tests/check-short-epoch-tvar-decode.sh}
    shellcheck -s bash ${../tests/check-pin-semantics.sh}
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
          pkgs.gnupatch
          amaruPkg
        ];
      } ''
      set -euo pipefail
      cp -rL ${cliMockTestTree}/. ./
      chmod -R u+w .
      patchShebangs tests
      bash tests/check-cli-mock-honesty.sh
      grep -q 'amaruSourceIdentity' ${../nix/amaru.nix}
      grep -q 'applyPatches' ${../nix/amaru.nix}
      grep -q 'builtins.hashFile' ${../nix/amaru.nix}
      grep -q 'recordedAmaruPatchBase' ${../nix/amaru.nix}
      grep -F 'amaruPatchSha256 =' ${../nix/amaru.nix}
      grep -E -q 'remove.*patch|patch.*remove' ${../nix/amaru.nix}
      actual=$(sha256sum ${../nix/patches/amaru-node-bootstrap-era-history.patch} | cut -d' ' -f1)
      grep -F "amaruPatchSha256 = \"$actual\";" ${../nix/amaru.nix}
      bash ${../tests/check-pin-semantics.sh} \
        ${amaruPkg.patchedSource.src} \
        ${amaruPkg.patchedSource} \
        ${../nix/patches/amaru-node-bootstrap-era-history.patch} \
        ${../tests/fixtures/network-era-history-semantic-mutant.patch}
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
  # and chain stores, logged build.ledger_opened (historically
  # build_ledger), and stayed alive until the timeout instead of failing
  # during bootstrap.
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
      if ! grep -F -e 'build_ledger' -e 'build.ledger_opened' "$log"; then
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
          pkgs.gawk
          pkgs.gnugrep
          pkgs.gnutar
          pkgs.jq
          pkgs.python3
          pkgs.rocksdb.tools
          pkgs.zstd
          amaruPkg
        ];
      } ''
      set -euo pipefail

      # amaru node run builds a reqwest client at startup; needs a CA anchor.
      export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt

      cp -rL ${shortEpochBootstrapBundle}/testnet_42 $TMPDIR/testnet_42
      chmod -R u+w $TMPDIR/testnet_42

      tests=${../tests}
      echo "tvar size-before-datatype mutant: ${tvarSizeBeforeDatatypeFailure}"
      log=${tvarSizeBeforeDatatypeFailure}/testBuildFailure.log
      grep -q 'complete definite-length map failed to import' "$log" || {
        echo "tvar size-before-datatype mutant: expected the complete-map positive control to fail" >&2
        cat "$log" >&2
        exit 1
      }
      grep -q 'end of input' "$log" || {
        echo "tvar size-before-datatype mutant: expected complete import to fail as end of input" >&2
        cat "$log" >&2
        exit 1
      }
      bash "$tests/check-short-epoch-utxo-set.sh" $TMPDIR/testnet_42

      # Short-epoch synthesis: epochLength=120, k=8, activeSlotsCoeff=1.0
      # => epoch_length = k*(1/f)*scale = 8*1*15.
      export AMARU_GLOBAL_CONSENSUS_SECURITY_PARAM=8
      export AMARU_GLOBAL_ACTIVE_SLOT_COEFF_INVERSE=1
      export AMARU_GLOBAL_EPOCH_LENGTH_SCALE_FACTOR=15
      bash "$tests/check-short-epoch-tvar-decode.sh" $TMPDIR/testnet_42

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
      if ! grep -F -e 'build_ledger' -e 'build.ledger_opened' "$log"; then
        echo "amaru did not reach ledger startup from the short-epoch bundle" >&2
        exit 1
      fi

      mkdir -p "$out"
    '';

}
