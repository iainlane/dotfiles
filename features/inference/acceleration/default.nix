{config, ...}: let
  inherit (config.flake) features;
in {
  flake.features.inference.provides.acceleration = {
    homeManager.imports = [../ollama/home-manager-options.nix];

    provides = {
      metal.includes = [features.inference.provides.acceleration];

      vulkan = {
        includes = [features.inference.provides.acceleration];

        nixos.hardware.graphics.enable = true;

        homeManager = {lib, ...}: {
          dotfiles.inference.ollama.requireAcceleration = lib.mkDefault true;
        };
      };
    };
  };
}
