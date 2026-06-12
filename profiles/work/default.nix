{
  inputs,
  config,
  withSystem,
  ...
}: let
  helpers = import ../helpers.nix {inherit inputs;};
  inherit (inputs.nixpkgs) lib;
  inherit (config.flake) mkLanguageShell;

  # Claude Code gets these via the enterprise subscription. Other harnesses can
  # still use them, but we need to add them manually.
  workMcp = {
    linear.url = "https://mcp.linear.app/mcp";
    slack.url = "https://mcp.slack.com/mcp";
    glean.url = "https://chainguard-be.glean.com/mcp/default";
  };

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
    modules = [config.flake.modules.ai config.flake.modules.git];

    homeManagerModule = {pkgs, ...} @ args:
      lib.recursiveUpdate
      (projectShells.homeManagerModule args)
      {
        home.packages = with pkgs; [
          chainctl
          melange
          wolfictl

          openssl

          slack
          vale
        ];

        dotfiles = {
          # Home Manager tools get the enterprise connectors here.
          ai.mcpServers = workMcp;
          # Claude Code receives these from the organisation, so don't dupe.
          claudeCode.excludeMcpServers = builtins.attrNames workMcp;

          git.signing.directories."~/dev/chainguard/".ssh.key = "~/.ssh/id_ed25519";
        };

        # Block the `/share` command so work sessions can't be uploaded to
        # opencode's public share service.
        programs.opencode.settings.share = "disabled";
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

        dotfiles.ai.mcpServers =
          lib.mkIf (helpers.hasProfile hostConfig "desktop") workMcp;

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
