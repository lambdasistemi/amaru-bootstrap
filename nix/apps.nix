{ pkgs
, amaruPkg
, iogTools
, headerExtractorPkgs
}:

# Runnable wrappers exposed via `nix run .#<name>`.
#
# `smoke-test` is Phase 0's deliverable. `bootstrap-producer` is the
# local-mode entrypoint of Phase 2 — it shells out to
# scripts/bootstrap-producer.sh with a PATH that puts the four
# bundled binaries ahead of any system installs (matching the
# image's contents per nix/bootstrap-producer-image.nix).
let
  smokeTest = pkgs.writeShellApplication {
    name = "smoke-test";
    runtimeInputs = [
      pkgs.jq
      amaruPkg
      iogTools.db-synthesizer
      iogTools.db-analyser
      iogTools.snapshot-converter
    ];
    text = ''
      exec ${../scripts/smoke-test.sh} "$@"
    '';
  };

  # T017-T019 land scripts/bootstrap-producer.sh; until then this
  # wrapper is a stub that exits 64 (internal-error class).
  # Bisect-safety: the app exists and evaluates, even though the
  # real entrypoint is not yet implemented.
  bootstrapProducer = pkgs.writeShellApplication {
    name = "bootstrap-producer";
    runtimeInputs = [
      pkgs.jq
      amaruPkg
      iogTools.db-analyser
      iogTools.snapshot-converter
      headerExtractorPkgs.header-extractor
    ];
    text = ''
      echo "bootstrap-producer stub: real script lands in T017-T019" >&2
      exit 64
    '';
  };

  mkApp = drv: bin: {
    type = "app";
    program = "${drv}/bin/${bin}";
  };
in
{
  smoke-test = mkApp smokeTest "smoke-test";
  bootstrap-producer = mkApp bootstrapProducer "bootstrap-producer";
  amaru = mkApp amaruPkg "amaru";
  db-synthesizer = mkApp iogTools.db-synthesizer "db-synthesizer";
  db-analyser = mkApp iogTools.db-analyser "db-analyser";
  snapshot-converter = mkApp iogTools.snapshot-converter "snapshot-converter";
  header-extractor = mkApp headerExtractorPkgs.header-extractor "header-extractor";
}
