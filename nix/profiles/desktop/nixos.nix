{config, ...}: let
  inherit (config.flake.modules) gnome;
  vmHost = config.flake.modules."vm-host";
  secureBoot = config.flake.modules."secure-boot";
in {
  flake.profiles.desktop.os.nixos = {
    modules = [gnome vmHost secureBoot];

    homeManagerModule = config.flake.profiles.desktop.os.linux.homeManagerModule;

    nixosModule = {pkgs, ...}: {
      fonts.packages = import ./fonts.nix pkgs;
    };
  };
}
