{inputs, ...}: let
  helpers = import ../../lib/helpers.nix {inherit inputs;};
in {
  imports =
    [
      ./apps.nix
      ./checks.nix
      ./context.nix
      ./darwin.nix
      ./deploy.nix
      ./direnvs.nix
      ./nix.nix
      ./modules.nix
      ./os.nix
      ./profiles.nix
      ./home.nix
      ./linux.nix
      ./nixos.nix
    ]
    ++ helpers.discoverModules ../../profiles
    ++ helpers.discoverModules ../../modules
    ++ helpers.discoverModules ../../os;

  # Make flake-parts aware of all our systems
  flake = {
    # Re-export for backwards compatibility if needed
    lib = import ../../lib/default.nix {inherit inputs;};
  };
}
