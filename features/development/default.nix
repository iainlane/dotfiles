{
  inputs,
  config,
  mkLanguageShell,
  withSystem,
  ...
}: let
  helpers = import ../../lib/helpers.nix {inherit inputs;};
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

  projectShells = helpers.mkProjectShells {
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

    os = {
      darwin.includes = [children.orbstack];
      "generic-linux".homeManager = ./home-manager-linux.nix;
      nixos.homeManager = ./home-manager-linux.nix;
    };

    homeManager = [
      projectShells.homeManagerModule
      ./home-manager.nix
    ];
  };
}
