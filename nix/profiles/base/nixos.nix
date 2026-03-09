{config, ...}: let
  inherit (config.flake.modules) borgmatic;
in {
  flake.profiles.base.os.nixos = {
    modules = [borgmatic];

    homeManagerModule = {pkgs, ...}: {
      home.packages = with pkgs; [
        deckmaster
        lurk
      ];
    };
  };
}
