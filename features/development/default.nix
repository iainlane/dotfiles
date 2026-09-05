{
  config,
  lib,
  mkLanguageShell,
  withSystem,
  ...
}: let
  inherit (import ../../lib/projects.nix {inherit lib;}) mkProjectShells;
  children = config.flake.features.development.provides;

  # Base dev directory with common tools
  projects = {
    dev = {
      directory = "dev";
      extraPackages = pkgs: with pkgs; [just];
    };

    dev-random-rust = {
      directory = "dev/random/rust";
      languages = ["rust"];
    };

    dev-random-go = {
      directory = "dev/random/go";
      languages = ["go"];
    };

    dev-random-python = {
      directory = "dev/random/python";
      languages = ["python"];
    };

    dev-random-typescript = {
      directory = "dev/random/typescript";
      languages = ["typescript"];
    };

    dev-random-lua = {
      directory = "dev/random/lua";
      languages = ["lua"];
    };
  };

  mkShell = pkgs: os: def: let
    langShell = mkLanguageShell pkgs os (def.languages or []);
    extra = (def.extraPackages or (_: [])) pkgs;
  in
    pkgs.mkShellNoCC (langShell
      // {
        packages = (langShell.packages or []) ++ extra;
      });

  projectShells = mkProjectShells {
    inherit config withSystem mkShell projects;
  };
in {
  imports = [
    projectShells.flakeModule
    ./debuginfod
    ./orbstack
  ];

  flake.features.development = {
    includes = [children.debuginfod];

    kernel.linux.homeManager = ./home-manager-linux.nix;

    os.darwin.includes = [children.orbstack];

    homeManager = [
      projectShells.homeManagerModule
      ./home-manager.nix
    ];
  };
}
