{pkgs, ...}: {
  typecheck = pkgs.runCommandLocal "typecheck-test" {passthru.ci.runOnce = true;} ''
    TYPECHECK_SCRIPT=${../../../lib/typecheck.ts} \
      TYPECHECK_TEST_SHELL=${pkgs.bash}/bin/bash \
      ${pkgs.nodejs}/bin/node --test ${../../../lib/typecheck.test.ts}
    touch $out
  '';
}
