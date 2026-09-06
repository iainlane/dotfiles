{
  config,
  lib,
  mkLanguageShell,
  withSystem,
  ...
}: let
  inherit (import ../../lib/projects.nix {inherit lib;}) mkProjectShell mkProjectShells;

  children = config.flake.features.work.provides;

  projects = let
    defaults = {
      name = "Iain Lane";
      email = "iain.lane@chainguard.dev";
      zshColour = "magenta";
    };
  in {
    dev-chainguard =
      defaults
      // {
        directory = "dev/chainguard";
        languages = ["go" "typescript"];
        extraPackages = pkgs:
          with pkgs; [
            stdenv.cc
            pkg-config

            apko
          ];
        extraPaths = ["$HOME/go/bin"];
      };

    dev-chainguard-rust =
      defaults
      // {
        directory = "dev/chainguard/rust";
        languages = ["rust"];
      };
  };

  mkShell = pkgs: kernel: def:
    mkProjectShell {
      inherit pkgs def;

      base = mkLanguageShell pkgs kernel (def.languages or []);

      environment =
        {
          NAME = def.name;
          EMAIL = def.email;
          GIT_AUTHOR_NAME = def.name;
          GIT_AUTHOR_EMAIL = def.email;
          GIT_COMMITTER_NAME = def.name;
          GIT_COMMITTER_EMAIL = def.email;
        }
        // lib.optionalAttrs ((def.zshColour or null) != null) {
          ZSH_USERNAME_COLOUR = def.zshColour;
        };
    };

  projectShells = mkProjectShells {
    inherit config withSystem mkShell projects;
  };
in {
  imports = [
    projectShells.flakeModule
    ./claude-managed-settings
    ./falcon
    ./kolide
  ];

  flake.features.work = {
    includes = [config.flake.features.ai config.flake.features.git];

    os.nixos.includes = with children; [falcon kolide];

    homeManager = [
      projectShells.homeManagerModule
      ./home-manager.nix
    ];
  };
}
