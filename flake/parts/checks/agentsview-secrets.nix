_: {
  perSystem = {pkgs, ...}: {
    checks.agentsview-secrets =
      pkgs.runCommandLocal "agentsview-secrets-test" {
        nativeBuildInputs = [
          pkgs.bash
          pkgs.coreutils
          pkgs.findutils
          pkgs.gnugrep
          pkgs.jq
          pkgs.yq-go
        ];
      }
      ''
        bash ${../../../scripts/generate-agentsview-secrets.test.bash} \
          ${../../../scripts/generate-agentsview-secrets.bash} \
          ${../../../scripts/lib/just-common.bash}

        touch $out
      '';
  };
}
