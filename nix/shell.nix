{ pkgs
, project
, amaruPkg
, iogTools
}:

# Dev shell: cabal/ghc come from haskell.nix's project shell; we
# augment it with the project's three binaries, plus shell utilities
# the orchestrator and tests need (just, jq, shellcheck, bats).
project.shellFor {
  withHoogle = false;
  tools = {
    cabal = "latest";
  };
  buildInputs = with pkgs; [
    just
    jq
    shellcheck
    bats
    amaruPkg
    iogTools.db-synthesizer
    iogTools.db-analyser
  ];
  exactDeps = true;
}
