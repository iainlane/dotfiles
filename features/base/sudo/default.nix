{
  flake.features.base.provides.sudo = {
    nixos = ./sudo-rules.nix;
    systemManager = ./sudo-rules.nix;
  };
}
