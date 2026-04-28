{ pkgs
, amaruPkg
, iogTools
, headerExtractor
}:

# Layered docker image carrying the bootstrap-producer.
#
# Reference: see
# specs/003-amaru-bootstrap-producer/research.md R-004 (image layout)
# and Obs#1 (entrypoint shebang — /bin/sh is dash on most distros and
# breaks bashisms; we use /bin/bash via the script's executable bit).
#
# Layered for cache-friendliness: heavy binary layers (db-analyser,
# snapshot-converter, amaru, header-extractor) persist across builds;
# only the orchestrator script's layer rebuilds when the orchestrator
# changes (it changes most often).
#
# T003 ships this skeleton with a stub orchestrator so the image
# builds; the real orchestrator script lands in T017-T019 and gets
# wired into the image's contents in T020.

let
  # NOTE: stub for bisect-safety, replaced in T020 by
  # ${../scripts/bootstrap-producer.sh} (with chmod +x and bash
  # shebang).
  stubScript = pkgs.writeShellApplication {
    name = "bootstrap-producer";
    runtimeInputs = [ pkgs.bash pkgs.coreutils ];
    text = ''
      echo "bootstrap-producer stub: real script lands in T017-T019" >&2
      exit 64
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
    pkgs.jq
    iogTools.db-analyser
    iogTools.snapshot-converter
    headerExtractor
    amaruPkg
    stubScript
  ];

  config = {
    Entrypoint = [ "${stubScript}/bin/bootstrap-producer" ];
    Cmd = [ ];
  };
}
