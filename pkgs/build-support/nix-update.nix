{
  fetchFromGitHub,
  lib,
  nix-update,
  nixpkgsPath,
  python3Packages,
  writeShellApplication,
}: let
  # A candidate nixpkgs pin must not bring back the flake store-path bug.
  minimumVersion = "1.17.0";
  updater =
    if lib.versionOlder nix-update.version minimumVersion
    then
      nix-update.overridePythonAttrs (_: {
        version = minimumVersion;
        src = fetchFromGitHub {
          owner = "Mic92";
          repo = "nix-update";
          tag = "v${minimumVersion}";
          hash = "sha256-TCOhUWb53V3nrJRD3JuADly1U9fNi0Z79QMcjhbefHg=";
        };
        build-system = [python3Packages.hatchling];
        dependencies = [python3Packages.ast-grep-py];
      })
    else nix-update;
in
  writeShellApplication {
    name = "nix-update";
    text = ''
      # The merged-patch check uses import <nixpkgs>, even in flake mode.
      export NIX_PATH=${lib.escapeShellArg "nixpkgs=${nixpkgsPath}"}"''${NIX_PATH:+:$NIX_PATH}"
      exec ${lib.getExe updater} "$@"
    '';
  }
