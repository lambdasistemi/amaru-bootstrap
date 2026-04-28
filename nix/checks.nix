{ pkgs
, amaruPkg
, iogTools
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
  snapshot-converter = iogTools.snapshot-converter;

  shellcheck = pkgs.runCommand "smoke-test-shellcheck"
    {
      nativeBuildInputs = [ pkgs.shellcheck ];
    } ''
    shellcheck -s bash -e SC1091 ${scriptSrc}
    mkdir -p $out
  '';

  # Unit-style bats: pure mock-based tests, no real binaries needed.
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

  # Integration: real binaries. THIS is the Phase 0/1 deliverable.
  # Phase 0 wires test-smoke-integration (FAIL: format mismatch is
  # acceptable). Phase 1 adds test-smoke-pass (asserts PASS) once the
  # orchestrator wires snapshot-converter in.
  smoke-test-integration = pkgs.runCommand "smoke-test-integration"
    {
      nativeBuildInputs = [
        pkgs.bash
        pkgs.bats
        pkgs.jq
        amaruPkg
        iogTools.db-synthesizer
        iogTools.db-analyser
        iogTools.snapshot-converter
      ];
    } ''
    cp -rL ${testTree}/. ./
    chmod -R u+w .
    patchShebangs scripts tests
    bats --tap tests/test-smoke-integration.bats
    mkdir -p $out
  '';

  smoke-test-pass = pkgs.runCommand "smoke-test-pass"
    {
      nativeBuildInputs = [
        pkgs.bash
        pkgs.bats
        pkgs.jq
        amaruPkg
        iogTools.db-synthesizer
        iogTools.db-analyser
        iogTools.snapshot-converter
      ];
    } ''
    cp -rL ${testTree}/. ./
    chmod -R u+w .
    patchShebangs scripts tests
    bats --tap tests/test-smoke-pass.bats
    mkdir -p $out
  '';
}
