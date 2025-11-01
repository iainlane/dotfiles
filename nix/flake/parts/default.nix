{
  inputs,
  lib,
  ...
}: let
  # What OS names do our hosts have?
  hostFiles = lib.filterAttrs (n: t: t == "regular" && lib.hasSuffix ".nix" n) (builtins.readDir ../../hosts);
  validOsNames = lib.unique (lib.mapAttrsToList (name: _: (import (../../hosts + "/${name}")).os) hostFiles);

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
  ) (lib.attrNames (lib.filterAttrs (_: type: type == "directory") (builtins.readDir ../../profiles)));
in {
  imports =
    [
      ./checks.nix
      ./context.nix
      ./darwin.nix
      ./deploy.nix
      ./direnvs.nix
      ./home-manager-modules.nix
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
