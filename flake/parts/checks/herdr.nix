{inputs, ...}: {
  perSystem = {
    pkgs,
    system,
    ...
  }: let
    inherit (pkgs) lib;

    herdrDir = ../../../features/ai/herdr;
    packages = pkgs.callPackage (herdrDir + "/packages.nix") {};
    inherit (inputs.llm-agents.packages.${system}) herdr;

    pluginSync = packages.pluginSync {inherit herdr;};
  in {
    checks.herdr-disp-model-updater =
      pkgs.runCommandLocal "herdr-disp-model-updater-test" {
        nativeBuildInputs = [pkgs.bash pkgs.jq pkgs.diffutils];
      } ''
        bash ${../../../pkgs/herdr-disp-model/update.test.sh} \
          ${../../../pkgs/herdr-disp-model/update.sh} \
          ${../../../pkgs/build-support/replace-once.jq}
        touch "$out"
      '';

    checks.herdr-plugin-sync =
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
  };
}
