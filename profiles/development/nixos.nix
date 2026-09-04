{config, ...}: {
  flake.features.development.os.nixos.homeManager = config.flake.features.development.os.linux.homeManager;
}
