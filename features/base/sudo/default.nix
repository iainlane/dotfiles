{
  dotfiles.features.base.sudo = {
    nixos = ./sudo-rules.nix;
    systemManager = ./system-manager.nix;
  };
}
