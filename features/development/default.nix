{
  featureResolver,
  config,
  lib,
  mkLanguageShell,
  ...
}: let
  inherit (import ../../lib/projects.nix {inherit lib;}) mkProjectShell mkProjectShells;
  children = config.dotfiles.features.development;

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

  mkShell = pkgs: platform: def:
    mkProjectShell {
      inherit pkgs def;
      base = mkLanguageShell pkgs platform (def.languages or []);
    };

  projectShells = mkProjectShells {
    inherit mkShell projects;
  };
in {
  imports = [
    ./languages.nix
    ./debuginfod
    ./orbstack
  ];

  dotfiles.flakeSystem.includes = [config.dotfiles.features.development];

  dotfiles.features.development = {
    checks = ../../lib/project-directories/check.nix;
    includes =
      [children.debuginfod]
      ++ [
        (featureResolver.when featureResolver.isLinux [{homeManager = ./home-manager-linux.nix;}])
        (featureResolver.when featureResolver.isDarwin [children.orbstack])
      ];

    homeManager = [
      projectShells.homeManagerModule
      ./home-manager.nix
    ];
  };
}
