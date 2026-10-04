{
  config,
  lib,
  ...
}: {
  perSystem = {pkgs, ...}: {
    checks =
      {
        trmnl-framework-updater = assert builtins.elem "trmnl-framework" config.flake.updaterNames;
          pkgs.runCommandLocal "trmnl-framework-updater-test" {
            nativeBuildInputs = [pkgs.bash pkgs.jq pkgs.diffutils];
          } ''
            bash ${../../../pkgs/trmnl-framework/update.test.sh} \
              ${../../../pkgs/trmnl-framework/update.sh}
            touch $out
          '';
        larapaper-updater = assert builtins.elem "larapaper" config.flake.updaterNames;
          pkgs.runCommandLocal "larapaper-updater-test" {
            nativeBuildInputs = [pkgs.bash pkgs.jq pkgs.python3];
          } ''
            bash ${../../../pkgs/larapaper/update.test.sh} \
              ${../../../pkgs/larapaper/update.sh}
            touch $out
          '';
      }
      // lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "x86_64-linux") {
        larapaper = pkgs.callPackage ../../../pkgs/larapaper-image/test.nix {};
      };
  };
}
