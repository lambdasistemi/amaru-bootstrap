{ pkgs
, amaruPkg
, iogTools
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
in
{
  amaru = amaruPkg;
  db-synthesizer = iogTools.db-synthesizer;
  db-analyser = iogTools.db-analyser;

  shellcheck = pkgs.runCommand "smoke-test-shellcheck"
    {
      nativeBuildInputs = [ pkgs.shellcheck ];
    } ''
    shellcheck -s bash -e SC1091 ${scriptSrc}
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
