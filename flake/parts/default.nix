{inputs, ...}: let
  discovery = import ../../lib/discovery.nix {inherit (inputs.nixpkgs) lib;};
in {
  imports =
    [
      ./apps.nix
      ./context.nix
      ./cupboard.nix
      ./deploy.nix
      ./direnv-languages.nix
      ./direnvs.nix
      ./features.nix
      ./git-hooks.nix
      ./hosts.nix
      ./nix.nix
      ./pkgs.nix
      ./treefmt.nix
      ./updaters.nix
    ]
    ++ discovery.discoverModuleFiles ./checks
    ++ discovery.discoverModuleFiles ../../hosts
    ++ discovery.discoverModules ../../features;
}
