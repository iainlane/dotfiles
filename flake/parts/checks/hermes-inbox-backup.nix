_: {
  perSystem = {pkgs, ...}: {
    checks.hermes-inbox-backup =
      pkgs.runCommandLocal "hermes-inbox-backup-test" {
        nativeBuildInputs = [
          pkgs.bash
          pkgs.coreutils
          pkgs.python3
          pkgs.rsync
          pkgs.sqlite
        ];
      }
      ''
        bash ${../../../features/hermes/backup/backup-inbox.test.bash} \
          ${../../../features/hermes/backup/backup-r2.sh}

        touch $out
      '';
  };
}
