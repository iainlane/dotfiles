{pkgs, ...}: {
  agentsview-backup =
    pkgs.runCommandLocal "agentsview-backup-test" {
      nativeBuildInputs = with pkgs; [bash coreutils diffutils findutils pv];
    } ''
      bash ${./backup.test.bash} ${./backup-r2.sh} ${pkgs.pv}/bin/pv
      touch "$out"
    '';
}
