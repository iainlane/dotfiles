{
  config,
  featureResolver,
  ...
}: let
  inherit (config.flake) features;
in {
  flake.features.inference.provides.acceleration = {
    checks = import ./checks.nix {inherit features featureResolver;};
    homeManager.imports = [../ollama/home-manager-options.nix];

    provides = {
      metal.includes = [features.inference.provides.acceleration];

      vulkan = {
        includes = [features.inference.provides.acceleration];

        nixos.hardware.graphics.enable = true;

        provides.integrated = {
          includes = [
            features.inference.provides.acceleration.provides.vulkan
            (featureResolver.when featureResolver.isGenericLinux [
              {homeManager.services.ollama.environmentVariables.OLLAMA_IGPU_ENABLE = "1";}
            ])
          ];

          nixos.services.ollama.environmentVariables.OLLAMA_IGPU_ENABLE = "1";
        };

        homeManager = {lib, ...}: {
          dotfiles.inference.ollama.requireAcceleration = lib.mkDefault true;
        };
      };
    };
  };
}
