{lib, ...}: let
  # Auto-discover all profile flake-parts modules
  # Profiles are flake-parts modules that contribute `homeManagerModules`.
  # Profiles with project directories also contribute direnvs and devShells.
  profileModules = lib.pipe (builtins.readDir ../../profiles) [
    (lib.filterAttrs (_name: type: type == "directory"))
    (lib.mapAttrsToList (name: _: ../../profiles + "/${name}/default.nix"))
    (lib.filter builtins.pathExists)
  ];
in {
  imports =
    [
      ./context.nix
      ./flake-options.nix
      ./home.nix
      ./darwin.nix
      ./linux.nix
      ./deploy.nix
      ./checks.nix
    ]
    ++ profileModules;
}
