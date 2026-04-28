{ pkgs
, amaruPkg
, iogTools
, snapshotEmitterPkg
}:

# Runnable wrappers exposed via `nix run .#<name>`.
#
# `smoke-test` is the project's primary deliverable: one command that
# runs the full Phase 0 pipeline (now Phase-1-bridged via
# snapshot-emitter) and emits a verdict. It wraps scripts/smoke-test.sh
# with a PATH that puts every tool the orchestrator invokes ahead of
# any system installs.
let
  smokeTest = pkgs.writeShellApplication {
    name = "smoke-test";
    runtimeInputs = [
      pkgs.jq
      amaruPkg
      iogTools.db-synthesizer
      iogTools.db-analyser
      snapshotEmitterPkg
    ];
    text = ''
      exec ${../scripts/smoke-test.sh} "$@"
    '';
  };

  mkApp = drv: bin: {
    type = "app";
    program = "${drv}/bin/${bin}";
  };
in
{
  smoke-test = mkApp smokeTest "smoke-test";
  amaru = mkApp amaruPkg "amaru";
  db-synthesizer = mkApp iogTools.db-synthesizer "db-synthesizer";
  db-analyser = mkApp iogTools.db-analyser "db-analyser";
  snapshot-emitter = mkApp snapshotEmitterPkg "snapshot-emitter";
}
