{pkgs, ...}: {
  agentsview-secrets =
    pkgs.runCommandLocal "agentsview-secrets-test" {
      nativeBuildInputs = [
        pkgs.age
        pkgs.bash
        pkgs.coreutils
        pkgs.findutils
        pkgs.gnugrep
        pkgs.jq
        pkgs.openssl
        pkgs.sops
        pkgs.yq-go
      ];
    }
    ''
      bash ${../../scripts/generate-agentsview-secrets.test.bash} \
        ${../../scripts/generate-agentsview-secrets.bash} \
        ${../../scripts/lib/just-common.bash} \
        ${pkgs.openssl}/bin/openssl \
        ${pkgs.sops}/bin/sops \
        ${pkgs.age}/bin/age-keygen

      touch $out
    '';
}
