_: {
  perSystem = {pkgs, ...}: {
    checks.nix-retry =
      pkgs.runCommandLocal "nix-retry-test" {
        nativeBuildInputs = [
          pkgs.bash
          pkgs.coreutils
        ];
      }
      ''
        bash ${../../../scripts/nix-retry.test.bash} \
          ${../../../scripts/nix-retry.bash}

        touch $out
      '';
  };
}
