{ pkgs
, amaruPkg
, iogTools
, snapshotEmitterPkg
}:

# Flake checks: a derivation per artefact. Each test check builds a
# minimal source tree at evaluation time using pkgs.linkFarm so paths
# inside the sandbox resolve identically to a local checkout
# (`./scripts`, `./tests`, `./specs/.../fixtures`). This avoids
# surprising path-resolution bugs that came from manually stitching
# files into a runCommand output.
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
in
{
  amaru = amaruPkg;
  db-synthesizer = iogTools.db-synthesizer;
  db-analyser = iogTools.db-analyser;
  snapshot-emitter = snapshotEmitterPkg;

  shellcheck = pkgs.runCommand "smoke-test-shellcheck"
    {
      nativeBuildInputs = [ pkgs.shellcheck ];
    } ''
    shellcheck -s bash -e SC1091 ${scriptSrc}
    mkdir -p $out
  '';

  # Unit-style bats: pure mock-based tests, no real binaries needed.
  # Wires T010 + T011 from 001-snapshot-format-smoke and T005 from
  # 002-snapshot-emitter (config-error tests for the emitter).
  smoke-test-bats = pkgs.runCommand "smoke-test-bats"
    {
      nativeBuildInputs = [ pkgs.bash pkgs.bats pkgs.jq ];
    } ''
    cp -rL ${testTree}/. ./
    chmod -R u+w .
    patchShebangs scripts tests
    bats --tap \
      tests/test-config-error.bats \
      tests/test-tool-error.bats \
      ${if builtins.pathExists ../tests/test-emitter-config-error.bats
         then "tests/test-emitter-config-error.bats"
         else ""}
    mkdir -p $out
  '';

  # Integration: real binaries. THIS is the Phase 0/1 deliverable.
  # Phase 0 wires T012 (FAIL: format mismatch is acceptable). Phase 1
  # T015 will swap the assertion to PASS-only.
  smoke-test-integration = pkgs.runCommand "smoke-test-integration"
    {
      nativeBuildInputs = [
        pkgs.bash
        pkgs.bats
        pkgs.jq
        amaruPkg
        iogTools.db-synthesizer
        iogTools.db-analyser
        snapshotEmitterPkg
      ];
    } ''
    cp -rL ${testTree}/. ./
    chmod -R u+w .
    patchShebangs scripts tests
    bats --tap tests/test-smoke-integration.bats
    mkdir -p $out
  '';
}
