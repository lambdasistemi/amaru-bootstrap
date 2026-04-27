{ pkgs
, amaruPkg
, iogTools
}:

# Flake checks: a derivation per binary (so `nix flake check` warms the
# store and CI's Build Gate has a single command to run) plus a
# shellcheck derivation for the orchestrator.
#
# The smoke-test bats checks land in T021; this file will gain
# `smoke-test-bats` then.
{
  amaru = amaruPkg;
  db-synthesizer = iogTools.db-synthesizer;
  db-analyser = iogTools.db-analyser;

  shellcheck =
    let
      script = ../scripts/smoke-test.sh;
    in
    if builtins.pathExists script
    then
      pkgs.runCommand "smoke-test-shellcheck"
        {
          nativeBuildInputs = [ pkgs.shellcheck ];
        }
        ''
          shellcheck -s bash -e SC1091 ${script}
          mkdir -p $out
        ''
    else
      pkgs.runCommand "smoke-test-shellcheck-pending" { } ''
        echo "scripts/smoke-test.sh not yet implemented (T013-T020)" >&2
        mkdir -p $out
      '';
}
