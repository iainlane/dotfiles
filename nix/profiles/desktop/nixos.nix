{config, ...}: let
  inherit (config.flake.modules) gnome;
  vmHost = config.flake.modules."vm-host";
  secureBoot = config.flake.modules."secure-boot";
in {
  flake.profiles.desktop.os.nixos = {
    modules = [gnome vmHost secureBoot];

    inherit (config.flake.profiles.desktop.os.linux) homeManagerModule;

    nixosModule = {
      pkgs,
      lib,
      config,
      ...
    }: {
      fonts.packages = import ./fonts.nix pkgs;

      boot = {
        consoleLogLevel = lib.mkDefault 0;
        initrd.verbose = false;
        kernelParams = [
          "quiet"
          "loglevel=3"
          "vt.global_cursor_default=0"
          "rd.systemd.show_status=false"
          "rd.udev.log_level=3"
          "udev.log_priority=3"
        ];
        plymouth = {
          enable = true;
          extraConfig = "UseSimpledrm=1";
          logo = pkgs.runCommand "transparent-plymouth-logo.png" {} ''
            ${pkgs.imagemagick}/bin/magick -size 1x1 xc:transparent PNG32:$out
          '';
        };
      };

      catppuccin.plymouth = {
        enable = config.boot.plymouth.enable;
        flavor = "mocha";
      };
    };
  };
}
