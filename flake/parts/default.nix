{inputs, ...}: let
  helpers = import ../../lib/helpers.nix {inherit inputs;};
in {
  imports =
    [
      ./apps.nix
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
      ./treefmt.nix
      ./updaters.nix
    ]
    ++ map (name: ./checks + "/${name}") (helpers.fileNames ./checks ".nix")
    ++ helpers.discoverModules ../../profiles
    ++ helpers.discoverModules ../../modules;
}
