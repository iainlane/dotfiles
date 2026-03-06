{inputs, ...}: let
  helpers = import ../../lib/helpers.nix {inherit inputs;};

  # Auto-discover profile flake-parts modules.
  profileModules =
    map
    (profileName: ../../profiles + "/${profileName}/default.nix")
    (helpers.directoryNames ../../profiles);
in {
  imports =
    [
      ./apps.nix
      ./checks.nix
      ./context.nix
      ./darwin.nix
      ./deploy.nix
      ./direnvs.nix
      ./profiles.nix
      ./home.nix
      ./linux.nix
    ]
    ++ profileModules;

  # Make flake-parts aware of all our systems
  flake = {
    # Re-export for backwards compatibility if needed
    lib = import ../../lib/default.nix {inherit inputs;};
  };
}
