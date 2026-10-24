{
  dotfiles.features.base.sudo = {
    nixos = ./sudo-rules.nix;
    systemManager = ./sudo-rules.nix;
  };
}
