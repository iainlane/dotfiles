{
  featureResolver,
  config,
  lib,
  mkLanguageShell,
  ...
}: let
  inherit (import ../../lib/projects.nix {inherit lib;}) mkProjectShell mkProjectShells;

  children = config.dotfiles.features.work;

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

  mkShell = pkgs: platform: def:
    mkProjectShell {
      inherit pkgs def;

      base = mkLanguageShell pkgs platform (def.languages or []);

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
    inherit mkShell projects;
  };
in {
  imports = [
    ./claude-managed-settings
    ./falcon
    ./kolide
  ];

  dotfiles.features.work = {
    inventory = {lib, ...}: {agentsview.archive.publish = lib.mkForce false;};
    inherit (projectShells) devShells legacyPackages;
    includes =
      [config.dotfiles.features.ai config.dotfiles.features.git]
      ++ [
        (featureResolver.when featureResolver.isNixos (with children; [falcon kolide]))
      ];

    homeManager = [
      projectShells.homeManagerModule
      ./home-manager.nix
    ];
  };
}
