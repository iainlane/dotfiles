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
