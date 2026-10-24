{
  config,
  featureResolver,
  ...
}: {
  dotfiles.flakeSystem.includes = [config.dotfiles.features.inference.ollama];
  dotfiles.features.inference.ollama = {
    checks = ./checks.nix;
    includes = [
      (featureResolver.when featureResolver.isDarwin [{homeManager = ./home-manager.nix;}])
      (featureResolver.when featureResolver.isLinux [{homeManager = ./home-manager-linux.nix;}])
    ];
    nixos = ./nixos.nix;
    homeManager.imports = [./home-manager-options.nix];
  };
}
