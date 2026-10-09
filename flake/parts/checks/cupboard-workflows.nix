{
  config,
  lib,
  ...
}: {
  perSystem = {pkgs, ...}: {
    checks.cupboard-workflows =
      pkgs.runCommandLocal "cupboard-workflows-test" {
        nativeBuildInputs = [pkgs.jq pkgs.yq-go];
      }
      ''
        CUPBOARD_SHARED_NIX_CONFIG=${pkgs.writeText "shared-nix.conf" config.flake.nix.substituterConfig} \
          CUPBOARD_PUBLISH_NIX_CONFIG=${pkgs.writeText "publish-nix.conf" config.flake.nix.publishSubstituterConfig} \
          CUPBOARD_TARGET_FIXTURE=${pkgs.writeText "cupboard-target-fixture.json" (builtins.toJSON (import ../../../scripts/cupboard-workflows.fixture.nix {inherit lib;}))} \
          CUPBOARD_WORKFLOWS=${../../../.github/workflows} \
          CUPBOARD_WORKFLOWS_BASH=${pkgs.bash}/bin/bash \
          ${pkgs.nodejs}/bin/node --experimental-strip-types --test \
          ${../../../scripts/cupboard-workflows.test.ts}

        touch $out
      '';
  };
}
