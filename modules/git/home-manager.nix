{
  config,
  pkgs,
  lib,
  ...
}: let
  cfg = config.dotfiles.git.signing;

  signingType = lib.types.attrTag {
    none = lib.mkOption {
      type = lib.types.submodule {};
      description = "Commit signing disabled.";
    };

    openpgp = lib.mkOption {
      type = lib.types.submodule {
        options.key = lib.mkOption {
          type = lib.types.str;
          description = "The OpenPGP key ID to sign with.";
        };
      };
      description = "Sign with an OpenPGP key.";
    };

    ssh = lib.mkOption {
      type = lib.types.submodule {
        options.key = lib.mkOption {
          type = lib.types.str;
          description = "Path to the SSH key to sign with.";
        };
      };
      description = "Sign with an SSH key.";
    };

    gitsign = lib.mkOption {
      type = lib.types.submodule {
        options.connectorID = lib.mkOption {
          type = lib.types.str;
          default = "https://accounts.google.com";
          description = "The OIDC connector used to authenticate.";
        };
      };
      description = "Sign with gitsign (Sigstore keyless signing).";
    };
  };

  # Render one signing configuration as raw git settings. Consumed for the
  # global configuration and for each per-directory include.
  signingSettings = scfg:
    if scfg ? none
    then {}
    else
      {
        commit.gpgsign = true;
        tag.gpgsign = true;
      }
      // (
        if scfg ? openpgp
        then {
          gpg.format = "openpgp";
          user.signingkey = scfg.openpgp.key;
        }
        else if scfg ? ssh
        then {
          gpg.format = "ssh";
          gpg.ssh.program = lib.getExe' pkgs.openssh "ssh-keygen";
          user.signingkey = scfg.ssh.key;
        }
        else {
          gpg.format = "x509";
          gpg.x509.program = lib.getExe' pkgs.gitsign "gitsign";
          gitsign.connectorID = scfg.gitsign.connectorID;
        }
      );

  usesGitsign =
    (cfg.global ? gitsign)
    || lib.any (scfg: scfg ? gitsign) (lib.attrValues cfg.directories);
in {
  options.dotfiles.git.signing = {
    global = lib.mkOption {
      type = signingType;
      default = {none = {};};
      description = "Commit signing for repositories not matched by `directories`.";
    };

    directories = lib.mkOption {
      type = lib.types.attrsOf signingType;
      default = {};
      description = ''
        Commit signing per directory tree, keyed by gitdir pattern. End the
        pattern with "/" to match every repository under it, for example
        "~/dev/chainguard/".
      '';
    };
  };

  config = {
    home.packages = lib.mkIf usesGitsign [pkgs.gitsign];

    programs.git = {
      enable = true;

      package = pkgs.gitFull;

      ignores = [
        # macOS metadata
        ".DS_Store"
        # Local Claude preferences that vary per machine.
        ".claude/settings.local.json"
        # Crush's working directory; it is recreated on demand.
        ".crush"

        # direnv
        ## state
        ".direnv"
        ## these are config but usually we don't want to commit them
        ".envrc"
        "flake.nix"
        "flake.lock"
      ];

      includes = lib.mkAfter (
        lib.mapAttrsToList (dir: scfg: {
          condition = "gitdir:${dir}";
          contents = signingSettings scfg;
        })
        cfg.directories
      );

      settings = lib.mkMerge [
        {
          user = {
            name = lib.mkDefault "Iain Lane";
            email = lib.mkDefault "iain@orangesquash.org.uk";
          };

          alias = {
            # Fetch a GitLab merge request by ID.
            mr = "!sh -c 'git fetch $0 merge-requests/$1/head'";
            # Pull a branch named like the current branch from origin.
            pb = "!sh -c 'git fetch origin \"$0:$0\"'";
            # Show the diff against the upstream tracking branch.
            du = "diff '@{u}'";
          };
          color.ui = true;
          push.default = "current";

          diff.tool = "nvimdiff";
          difftool.prompt = false;

          merge.tool = "diffview";

          mergetool = {
            prompt = false;
            keepBackup = false;
            diffview.cmd = "nvim -c \"DiffviewOpen\" \"\${MERGE}\"";
          };

          rerere.enabled = true;
          rebase.autosquash = true;
          pull.ff = "only";
          init.defaultBranch = "main";

          pager = {
            diff = "delta";
            log = "delta";
            reflog = "delta";
            show = "delta";
          };

          delta = {
            navigate = true;

            catppuccin-latte = {
              light = true;
              syntax-theme = "Catppuccin Latte";
            };

            catppuccin-mocha = {
              dark = true;
              syntax-theme = "Catppuccin Mocha";
            };
          };

          interactive.diffFilter = "delta --color-only";

          # Rewrite SSH GitHub URLs to HTTPS for pushes.
          "url \"https://github.com/\"".insteadOf = [
            "git@github.com:"
            "ssh://git@github.com/"
          ];
        }
        (signingSettings cfg.global)
      ];
    };
  };
}
