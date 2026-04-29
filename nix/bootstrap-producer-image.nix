{ pkgs
, amaruPkg
, iogTools
, headerExtractor
, ledgerStateEmitter
}:

# Layered docker image carrying the bootstrap-producer.
#
# Reference: see
# specs/003-amaru-bootstrap-producer/research.md R-004 (image layout)
# and Obs#1 (entrypoint shebang — /bin/sh is dash on most distros and
# breaks bashisms; we use /bin/bash via the script's executable bit).
#
# Layered for cache-friendliness: heavy binary layers
# (ledger-state-emitter, amaru, header-extractor) persist across
# builds; only the orchestrator script's layer rebuilds when the
# orchestrator changes (it changes most often).
#
# The image entrypoint is a small Nix wrapper that supplies PATH and
# invokes the in-repo bash orchestrator directly with Nix's bash. This
# avoids relying on /usr/bin/env inside the minimal dockerTools root.

let
  bootstrapProducer = pkgs.writeShellApplication {
    name = "bootstrap-producer";
    runtimeInputs = [
      pkgs.bash
      pkgs.coreutils
      pkgs.findutils
      pkgs.gawk
      pkgs.jq
      ledgerStateEmitter
      headerExtractor
      amaruPkg
    ];
    text = ''
      exec ${pkgs.bash}/bin/bash ${../scripts/bootstrap-producer.sh} "$@"
    '';
  };

in
pkgs.dockerTools.buildLayeredImage {
  name = "amaru-bootstrap-producer";
  tag = "dev";

  contents = [
    pkgs.dockerTools.binSh
    pkgs.bash
    pkgs.coreutils
    pkgs.findutils
    pkgs.gawk
    pkgs.jq
    ledgerStateEmitter
    headerExtractor
    amaruPkg
    bootstrapProducer
  ];

  config = {
    Entrypoint = [ "${bootstrapProducer}/bin/bootstrap-producer" ];
    Cmd = [ ];
  };
}
