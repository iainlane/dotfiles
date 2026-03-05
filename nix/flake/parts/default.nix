{
  inputs,
  lib,
  ...
}: let
  helpers = import ../../lib/helpers.nix {inherit inputs;};

  # What OS names do our hosts have?
  inherit (helpers) hosts;
  validOsNames = helpers.hostOsNames hosts;

  # Auto-discover profile flake-parts modules:
  #   default.nix - base profile module
  #   {os}.nix    - OS-specific module (e.g., linux.nix, darwin.nix)
  profileModules = lib.concatMap (
    profileName: let
      dir = ../../profiles + "/${profileName}";
      probe = filename: let
        filePath = dir + "/${filename}";
      in
        lib.optional (builtins.pathExists filePath) filePath;
    in
      probe "default.nix" ++ lib.concatMap (os: probe "${os}.nix") validOsNames
  ) (helpers.directoryNames ../../profiles);
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
