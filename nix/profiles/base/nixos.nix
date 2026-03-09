{config, ...}: let
  inherit (config.flake.modules) borgmatic;
in {
  flake.profiles.base.os.nixos = {
    modules = [borgmatic];

    homeManagerModule = {
      lib,
      ...
    }: {
      home.sessionPath = lib.mkForce [];
      targets.genericLinux.enable = false;
    };
  };
}
