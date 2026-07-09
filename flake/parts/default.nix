{inputs, ...}: let
  helpers = import ../../lib/helpers.nix {inherit inputs;};
in {
  imports =
    [
      ./apps.nix
      ./checks.nix
      ./checks-contracts.nix
      ./context.nix
      ./cupboard.nix
      ./deploy.nix
      ./direnvs.nix
      ./git-hooks.nix
      ./hosts.nix
      ./nix.nix
      ./modules.nix
      ./pkgs.nix
      ./profiles.nix
      ./updaters.nix
    ]
    ++ helpers.discoverModules ../../profiles
    ++ helpers.discoverModules ../../modules;
}
