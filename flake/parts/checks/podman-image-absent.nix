_: {
  perSystem = {pkgs, ...}: {
    checks.podman-image-absent =
      pkgs.runCommandLocal "podman-image-absent-test" {
        nativeBuildInputs = [
          pkgs.bash
          pkgs.coreutils
          pkgs.gnugrep
        ];
      }
      ''
        bash ${../../../lib/podman-image-absent.test.bash} \
          ${../../../lib/podman-image-absent.sh}

        touch $out
      '';
  };
}
