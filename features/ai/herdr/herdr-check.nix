{
  inputs,
  pkgs,
  system,
  ...
}: let
  inherit (pkgs) lib;

  herdrDir = ./.;
  packages = pkgs.callPackage (herdrDir + "/packages.nix") {};
  inherit (inputs.llm-agents.packages.${system}) herdr;

  pluginSync = packages.pluginSync {inherit herdr;};
in {
  herdr-annotate =
    pkgs.runCommandLocal "herdr-annotate-test" {
      nativeBuildInputs = [pkgs.python3];
    } ''
      python ${herdrDir + "/annotate.test.py"} \
        ${lib.getExe herdr} \
        ${pkgs.herdr-annotate.pluginRoot} \
        ${pkgs.herdr-annotate-links.pluginRoot} \
        ${lib.getExe inputs.llm-agents.packages.${system}.plannotator-tui}

      touch "$out"
    '';

  herdr-plugin-sync =
    pkgs.runCommandLocal "herdr-plugin-sync-test" {
      nativeBuildInputs = [
        pkgs.bash
        pkgs.coreutils
        pkgs.jq
      ];
    } ''
      bash ${herdrDir + "/plugin-sync.test.bash"} \
        ${lib.getExe herdr} \
        ${lib.getExe pluginSync}

      touch "$out"
    '';
}
