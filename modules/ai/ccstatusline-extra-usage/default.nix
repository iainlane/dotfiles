{pkgs, ...}:
# Helper for the Claude Code status line: prints month-to-date extra-usage
# spend read from ccstatusline's cached usage data. Wired into a
# `custom-command` widget in ../ccstatusline.nix via `lib.getExe`. See
# `extra-usage.sh` for the selection logic.
pkgs.writeShellApplication {
  name = "ccstatusline-extra-usage";
  runtimeInputs = with pkgs; [
    jq
    coreutils
  ];
  text = builtins.readFile ./extra-usage.sh;
}
