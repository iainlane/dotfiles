{
  inputs,
  config,
  withSystem,
  ...
}: let
  helpers = import ../helpers.nix {inherit inputs;};
  inherit (inputs.nixpkgs) lib;
  inherit (config.flake) mkLanguageShell;

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

  mkShell = pkgs: os: def: let
    langShell = mkLanguageShell pkgs os (def.languages or []);
    extra = (def.extraPackages or (_: [])) pkgs;
  in
    pkgs.mkShellNoCC (
      langShell
      // {
        packages = (langShell.packages or []) ++ extra;
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
    homeManagerModule = {pkgs, ...} @ args:
      lib.recursiveUpdate
      (projectShells.homeManagerModule args)
      {
        imports = [./gitsign.nix];

        home.packages = with pkgs; [
          chainctl
          melange
          wolfictl

          openssl

          slack
          vale
        ];

        programs = {
          git.includes = lib.mkAfter [
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

          mcp.servers.linear.url = "https://mcp.linear.app/mcp";

          # Block the `/share` command so work sessions can't be uploaded to
          # opencode's public share service.
          opencode.settings.share = "disabled";
        };
      };

    os.nixos = {
      modules = [config.flake.modules.falcon];

      nixosModule = {
        inputs,
        config,
        hostConfig,
        ...
      }: let
        secretsFile = inputs.secrets + "/${config.networking.hostName}/host-crowdstrike-falcon.yaml";
        falconRelease = import (inputs.secrets + "/crowdstrike/falcon.nix");
      in {
        imports =
          [./kolide.nix]
          ++ lib.optional (helpers.hasProfile hostConfig "desktop")
          ./claude-managed-settings.nix;

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
