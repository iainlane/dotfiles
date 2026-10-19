{pkgs, ...}: {
  unifi-backup =
    pkgs.runCommandLocal "unifi-backup-test" {
      nativeBuildInputs = [
        pkgs.bash
        pkgs.coreutils
        pkgs.diffutils
        pkgs.findutils
        pkgs.jq
      ];
    }
    ''
      bash ${./backup.test.bash} \
        ${./backup.sh}

      touch $out
    '';
}
