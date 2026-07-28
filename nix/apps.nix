{ pkgs
, amaruPkg
, iogTools
}:

# Runnable wrappers exposed via `nix run .#<name>`.
#
# `bootstrap-producer` is the local-mode entrypoint of Phase 2 — it
# shells out to scripts/bootstrap-producer.sh with a PATH that puts
# the bundled runtime tools ahead of any system installs (matching
# the image's contents per nix/bootstrap-producer-image.nix).
let
  bootstrapProducer = pkgs.writeShellApplication {
    name = "bootstrap-producer";
    runtimeInputs = [
      pkgs.bash
      pkgs.coreutils
      pkgs.findutils
      pkgs.gawk
      pkgs.jq
      amaruPkg
      iogTools.db-analyser
    ];
    text = ''
      exec ${pkgs.bash}/bin/bash ${../scripts/bootstrap-producer.sh} "$@"
    '';
  };

  mkApp = drv: bin: {
    type = "app";
    program = "${drv}/bin/${bin}";
  };
in
{
  bootstrap-producer = mkApp bootstrapProducer "bootstrap-producer";
  amaru = mkApp amaruPkg "amaru";
  db-synthesizer = mkApp iogTools.db-synthesizer "db-synthesizer";
  db-analyser = mkApp iogTools.db-analyser "db-analyser";
  snapshot-converter = mkApp iogTools.snapshot-converter "snapshot-converter";
}
