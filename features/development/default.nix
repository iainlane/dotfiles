{
  config,
  lib,
  mkLanguageShell,
  withSystem,
  ...
}: let
  inherit (import ../../lib/projects.nix {inherit lib;}) mkProjectShell mkProjectShells;
  children = config.flake.features.development.provides;

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

  mkShell = pkgs: kernel: def:
    mkProjectShell {
      inherit pkgs def;
      base = mkLanguageShell pkgs kernel (def.languages or []);
    };

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
