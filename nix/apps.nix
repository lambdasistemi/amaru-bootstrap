{ pkgs
, amaruPkg
, iogTools
}:

# Runnable wrappers exposed via `nix run .#<name>`.
#
# The smoke-test app is wired in T021 once scripts/smoke-test.sh
# exists; for now we expose only the three stock binaries, which is
# enough to manually rehearse the Phase 0 pipeline before the
# orchestrator lands.
let
  mkApp = drv: bin: {
    type = "app";
    program = "${drv}/bin/${bin}";
  };
in
{
  amaru = mkApp amaruPkg "amaru";
  db-synthesizer = mkApp iogTools.db-synthesizer "db-synthesizer";
  db-analyser = mkApp iogTools.db-analyser "db-analyser";
}
