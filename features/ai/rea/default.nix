{config, ...}: {
  dotfiles.features.ai.rea = {
    checks = import ./checks.nix {
      features = config.dotfiles.features;
    };
    homeManager = ./home-manager.nix;
    system = ./shared.nix;
  };

  dotfiles.flakeSystem.includes = [config.dotfiles.features.ai.rea];
}
