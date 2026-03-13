{inputs, ...}: let
  helpers = import ../../lib/helpers.nix {inherit inputs;};

  # Auto-discover profile flake-parts modules.
  profileModules =
    map
    (profileName: ../../profiles + "/${profileName}/default.nix")
    (helpers.directoryNames ../../profiles);

  # Auto-discover feature flake-parts modules.
  featureModules =
    map
    (moduleName: ../../modules + "/${moduleName}/default.nix")
    (builtins.filter
      (moduleName: builtins.pathExists (../../modules + "/${moduleName}/default.nix"))
      (helpers.directoryNames ../../modules));
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
      ./profiles.nix
      ./home.nix
      ./linux.nix
      ./nixos.nix
    ]
    ++ profileModules
    ++ featureModules;

  # Make flake-parts aware of all our systems
  flake = {
    # Re-export for backwards compatibility if needed
    lib = import ../../lib/default.nix {inherit inputs;};
  };
}
