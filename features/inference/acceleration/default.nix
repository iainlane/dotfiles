{
  config,
  featureResolver,
  ...
}: let
  inherit (config.dotfiles) features;
in {
  dotfiles.flakeSystem.includes = [config.dotfiles.features.inference.acceleration];
  dotfiles.features.inference.acceleration = {
    checks = import ./checks.nix {inherit features featureResolver;};
    homeManager.imports = [../ollama/home-manager-options.nix];

    metal.includes = [features.inference.acceleration];

    vulkan = {
      includes = [features.inference.acceleration];

      nixos.hardware.graphics.enable = true;

      integrated = {
        includes = [
          features.inference.acceleration.vulkan
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
}
