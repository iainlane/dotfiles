{config, ...}: let
  inherit (config.flake.modules) borgmatic;
in {
  flake.profiles.base.os.nixos = {
    modules = [borgmatic];

    nixosModule = {
      users.groups.ssh = {};

      services.openssh = {
        enable = true;
        settings = {
          PermitRootLogin = "no";
          PasswordAuthentication = false;
          KbdInteractiveAuthentication = false;
        };
        extraConfig = "AllowGroups ssh";
      };
    };

    homeManagerModule = {pkgs, ...}: {
      home.packages = import ./linux-packages.nix pkgs;
    };
  };
}
