{pkgs, ...}: let
  inherit (pkgs) bynfont;
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

  # Override the upstream kmsconvt@ template to add boot ordering. This
  # drop-in applies to all instances, including the ones logind starts on
  # demand through the autovt@ alias.
  systemd.services."kmsconvt@" = {
    after = [
      "systemd-user-sessions.service"
      "plymouth-quit-wait.service"
      "getty-pre.target"
      "dbus.service"
      "systemd-localed.service"
    ];
    before = ["getty.target"];
    unitConfig = {
      IgnoreOnIsolate = true;
      ConditionPathExists = "/dev/tty0";
    };
    serviceConfig.Type = "idle";
  };
}
