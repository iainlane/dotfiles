_: {
  perSystem = {pkgs, ...}: {
    checks.r2-verify =
      pkgs.runCommandLocal "r2-verify-test" {
        nativeBuildInputs = [
          pkgs.bash
          pkgs.coreutils
          pkgs.jq
        ];
      }
      ''
        bash ${../../../lib/r2-verify.test.bash} \
          ${../../../lib/r2.sh}

        touch $out
      '';
  };
}
