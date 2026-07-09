{config, ...}: {
  flake.profiles.desktop.os.nixos = {
    features = ["gnome" "vm-host" "secure-boot"];

    inherit (config.flake.profiles.desktop.os.linux) homeManagerModule;

    nixosModule = {usbguardStaticRules ? {}}: {
      pkgs,
      lib,
      config,
      ...
    }: {
      imports = [
        ./console.nix
        ./options.nix
      ];

      dotfiles.desktop.usbguard.staticRules = usbguardStaticRules;

      fonts.packages = import ../fonts.nix pkgs;

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
        inherit (config.boot.plymouth) enable;
        flavor = "mocha";
      };

      networking.firewall.trustedInterfaces = ["tailscale0"];

      services.pcscd.enable = true;
      services.tailscale = {
        enable = true;
        useRoutingFeatures = "client";
      };

      systemd.services.tailscaled.serviceConfig.Environment = [
        "TS_DEBUG_FIREWALL_MODE=nftables"
      ];
    };
  };
}
