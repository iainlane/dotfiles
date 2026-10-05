_: {
  perSystem = {pkgs, ...}: {
    checks.cupboard-workflows =
      pkgs.runCommandLocal "cupboard-workflows-test" {
        nativeBuildInputs = [pkgs.yq-go];
      }
      ''
        CUPBOARD_WORKFLOWS=${../../../.github/workflows} \
          CUPBOARD_WORKFLOWS_BASH=${pkgs.bash}/bin/bash \
          ${pkgs.nodejs}/bin/node --experimental-strip-types --test \
          ${../../../scripts/cupboard-workflows.test.ts}

        touch $out
      '';
  };
}
