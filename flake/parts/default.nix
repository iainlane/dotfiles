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
      ./features.nix
      ./git-hooks.nix
      ./hosts.nix
      ./nix.nix
      ./pkgs.nix
      ./treefmt.nix
      ./updaters.nix
    ]
    ++ map (name: ./checks + "/${name}") (helpers.fileNames ./checks ".nix")
    ++ helpers.discoverModuleFiles ../../hosts
    ++ helpers.discoverModules ../../features
    ++ helpers.discoverModules ../../modules;
}
