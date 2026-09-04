{config, ...}: {
  flake.features.development.os.nixos.homeManager = config.flake.features.development.os."generic-linux".homeManager;
}
