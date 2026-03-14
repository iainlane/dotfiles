{pkgs, ...}: let
  bynfont = pkgs.callPackage ./bynfont.nix {};
in {
  console = {
    font = "${bynfont}/share/consolefonts/bynfont.psfu.gz";
    keyMap = "uk";
    packages = [bynfont];
  };

  services = {
    xserver.xkb.layout = "gb";

    kmscon = {
      enable = true;
      hwRender = true;
      fonts = [
        {
          name = "MonaspiceNe NFM";
          package = pkgs.nerd-fonts.monaspace;
        }
      ];
      useXkbConfig = true;
    };
  };

  # Override the upstream kmsconvt@ template to add boot ordering and a
  # getty fallback. This drop-in applies to all instances (including those
  # spawned reactively by logind via the autovt@ alias).
  systemd.services."kmsconvt@" = {
    after = [
      "systemd-user-sessions.service"
      "plymouth-quit-wait.service"
      "getty-pre.target"
      "dbus.service"
      "systemd-localed.service"
    ];
    before = ["getty.target"];
    conflicts = ["getty@%i.service"];
    onFailure = ["getty@%i.service"];
    unitConfig = {
      IgnoreOnIsolate = true;
      ConditionPathExists = "/dev/tty0";
    };
    serviceConfig.Type = "idle";
  };

  # Explicitly start kmscon on VT1 at boot. NixOS's wantedBy on a bare
  # template (kmsconvt@) produces a symlink without an instance name which
  # systemd ignores. An explicit instance ensures kmscon runs on tty1.
  systemd.services."kmsconvt@tty1".wantedBy = ["getty.target"];
}
