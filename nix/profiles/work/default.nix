{
  inputs,
  config,
  withSystem,
  ...
}: let
  helpers = import ../helpers.nix {inherit inputs;};
  inherit (inputs.nixpkgs) lib;
  inherit (config.flake.modules) chainctl wolfictl;
  langPackages = config.flake.direnvPackages;

  projects = let
    defaults = {
      name = "Iain Lane";
      email = "iain.lane@chainguard.dev";
      zshColour = "magenta";
    };
  in {
    dev-chainguard-go =
      defaults
      // {
        directory = "dev/chainguard";
        packages = pkgs:
          (langPackages.go pkgs)
          ++ (with pkgs; [
            stdenv.cc
            pkg-config
          ]);
        extraPaths = ["$HOME/go/bin"];
      };

    dev-chainguard-rust =
      defaults
      // {
        directory = "dev/chainguard/rust";
        packages = langPackages.rust;
      };
  };

  mkShell = pkgs: def:
    pkgs.mkShellNoCC (
      {
        packages = def.packages or (_: []) pkgs;
      }
      // {
        NAME = def.name;
        EMAIL = def.email;
        GIT_AUTHOR_NAME = def.name;
        GIT_AUTHOR_EMAIL = def.email;
        GIT_COMMITTER_EMAIL = def.email;
      }
      // lib.optionalAttrs (def ? zshColour && def.zshColour != null) {
        ZSH_USERNAME_COLOUR = def.zshColour;
      }
    );

  projectShells = helpers.mkProjectShells {
    inherit config withSystem mkShell projects;
  };
in {
  imports = [projectShells.flakeModule];

  flake.profiles.work = {
    modules = [chainctl wolfictl];

    homeManagerModule = {pkgs, ...} @ args:
      lib.recursiveUpdate
      (projectShells.homeManagerModule args)
      {
        imports = [./gitsign.nix];

        home.packages = with pkgs; [
          slack
          vale
        ];

        programs.git.includes = lib.mkAfter [
          {
            condition = "gitdir:~/dev/chainguard/";
            contents = {
              commit.gpgsign = true;
              tag.gpgsign = true;
              gpg.format = "x509";
              gpg.x509.program = "${pkgs.gitsign}/bin/gitsign";
              gitsign.connectorID = "https://accounts.google.com";
            };
          }
        ];
      };

    os.nixos = {
      modules = [config.flake.modules.falcon];

      nixosModule = {
        inputs,
        config,
        ...
      }: let
        secretsFile = inputs.secrets + "/${config.networking.hostName}/host-crowdstrike-falcon.yaml";
        falconRelease = import (inputs.secrets + "/crowdstrike/falcon.nix");
      in {
        imports = [./kolide.nix];

        services.falcon-sensor = {
          enable = true;
          cidFile = config.sops.secrets.falcon-cid.path;
          release = falconRelease;
          traceLevel = "err";
        };

        sops.secrets = {
          falcon-cid = {
            mode = "0600";
            sopsFile = secretsFile;
          };
        };
      };
    };
  };
}
