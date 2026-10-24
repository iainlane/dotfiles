{
  systems,
  nixConfiguration,
  inputs,
  lib,
  ...
}: {pkgs, ...}: let
  fixture = import ../../../scripts/cupboard-workflows.fixture.nix {
    inherit lib inputs;
    inherit systems;
  };
in {
  checks.cupboard-workflows =
    pkgs.runCommandLocal "cupboard-workflows-test" {
      nativeBuildInputs = [pkgs.jq pkgs.yq-go];
    }
    ''
      CUPBOARD_SHARED_NIX_CONFIG=${pkgs.writeText "shared-nix.conf" nixConfiguration.substituterConfig} \
        CUPBOARD_PUBLISH_CACHE_CONFIG=${pkgs.writeText "publish-cache.conf" nixConfiguration.publishSubstituterConfig} \
        CUPBOARD_CI_NIX_CONFIG=${pkgs.writeText "ci-nix.conf" nixConfiguration.ciConfig} \
        CUPBOARD_PUBLISH_NIX_CONFIG=${pkgs.writeText "publish-nix.conf" nixConfiguration.publishCiConfig} \
        CUPBOARD_EVALUATION_SCRIPT=${../../../scripts/check-evaluation.bash} \
        CUPBOARD_EVALUATION_CONFIG=${../../../lib/nix/evaluation.conf} \
        CUPBOARD_TARGET_FIXTURE=${pkgs.writeText "cupboard-target-fixture.json" (builtins.toJSON fixture)} \
        CUPBOARD_WORKFLOWS=${../../../.github/workflows} \
        CUPBOARD_WORKFLOWS_BASH=${pkgs.bash}/bin/bash \
        ${pkgs.nodejs}/bin/node --experimental-strip-types --test \
        ${../../../scripts/cupboard-workflows.test.ts}

      touch $out
    '';
}
