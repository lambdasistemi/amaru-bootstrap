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
  runtimeInputs = [
    pkgs.bash
    pkgs.coreutils
    pkgs.findutils
    pkgs.gawk
    pkgs.gnused
    pkgs.jq
    ledgerStateEmitter
    headerExtractor
    amaruPkg
  ];

  bootstrapProducer = pkgs.writeShellApplication {
    name = "bootstrap-producer";
    runtimeInputs = runtimeInputs;
    text = ''
      exec ${pkgs.bash}/bin/bash ${../scripts/bootstrap-producer.sh} "$@"
    '';
  };

  # Antithesis amaru-relay-N container entrypoint. Lives in the image
  # so the cardano-node-antithesis docker-compose doesn't have to inline
  # 90 lines of bash. See scripts/amaru-relay-bootstrap.sh for the
  # env-var contract and behaviour.
  amaruRelayBootstrap = pkgs.writeShellApplication {
    name = "amaru-relay-bootstrap";
    runtimeInputs = runtimeInputs;
    text = ''
      exec ${pkgs.bash}/bin/bash ${../scripts/amaru-relay-bootstrap.sh} "$@"
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
    pkgs.gnused
    pkgs.jq
    ledgerStateEmitter
    headerExtractor
    amaruPkg
    bootstrapProducer
    amaruRelayBootstrap
  ];

  # Default entrypoint stays bootstrap-producer (the existing
  # consumer contract). Antithesis testnets that want the relay
  # wrapper override entrypoint to amaru-relay-bootstrap and pass
  # config via env (RELAY_NAME, AMARU_PEER, …).
  config = {
    Entrypoint = [ "${bootstrapProducer}/bin/bootstrap-producer" ];
    Cmd = [ ];
  };
}
