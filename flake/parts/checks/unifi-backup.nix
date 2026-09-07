_: {
  perSystem = {pkgs, ...}: {
    checks.unifi-backup =
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
        bash ${../../../features/unifi/backup/backup.test.bash} \
          ${../../../features/unifi/backup/backup.sh}

        touch $out
      '';
  };
}
