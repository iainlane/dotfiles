{config, ...}: {
  flake.profiles.development.os.nixos = {
    inherit (config.flake.profiles.development.os.linux) homeManagerModule;
  };
}
