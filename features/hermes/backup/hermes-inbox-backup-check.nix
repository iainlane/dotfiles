{pkgs, ...}: {
  hermes-inbox-backup =
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
      bash ${./backup-inbox.test.bash} \
        ${./backup-r2.sh}

      touch $out
    '';
}
