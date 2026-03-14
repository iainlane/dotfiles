{inputs, ...}: let
  helpers = import ../../lib/helpers.nix {inherit inputs;};
in {
  imports =
    [
      ./apps.nix
      ./checks.nix
      ./context.nix
      ./deploy.nix
      ./direnvs.nix
      ./hosts.nix
      ./nix.nix
      ./modules.nix
      ./profiles.nix
    ]
    ++ helpers.discoverModules ../../profiles
    ++ helpers.discoverModules ../../modules;
}
