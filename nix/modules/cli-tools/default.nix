_: let
  homeManagerModule = {
    inputs,
    pkgs,
    system,
    ...
  }: let
    # Pin less for bat until nixpkgs carries 692.
    #
    # less 691 regressed support for negative values in `-z`/`--window`
    # (for example `-z-4`), which breaks current LESS defaults.
    #
    # Keep this scoped to bat only so we do not force global rebuilds of packages
    # that happen to depend on `less` in their build graph.
    less692 = pkgs.less.overrideAttrs (_: {
      version = "692";
      src = pkgs.fetchurl {
        url = "https://greenwoodsoftware.com/less/less-692.tar.gz";
        hash = "sha256-YTAPYDeY7PHXeGVweJ8P8/WhrPB1pvufdWg30WbjfRQ=";
      };
    });
  in {
    imports = [
      ./fzf.nix
    ];

    home.packages = [
      pkgs.vhs
    ];

    catppuccin = {
      lazygit.enable = true;
    };

    programs = {
      bat = {
        enable = true;
        package = pkgs.bat.override {less = less692;};
        config = {
          style = "auto";
          theme = "auto";
          theme-dark = "Catppuccin Mocha";
          theme-light = "Catppuccin Latte";
        };
        themes = {
          "Catppuccin Mocha" = {
            src = inputs.catppuccin-bat;
            file = "themes/Catppuccin Mocha.tmTheme";
          };
          "Catppuccin Latte" = {
            src = inputs.catppuccin-bat;
            file = "themes/Catppuccin Latte.tmTheme";
          };
        };
        syntaxes = {
          just = {
            src = inputs.just-sublime;
            file = "Syntax/Just.sublime-syntax";
          };
        };
      };

      bottom.enable = true;

      btop.enable = true;

      direnv = {
        enable = true;
        package = inputs.nixpkgs-stable.legacyPackages.${system}.direnv;

        enableZshIntegration = true;
        nix-direnv.enable = true;
        silent = true;
      };

      eza = {
        enable = true;
        enableZshIntegration = true;
        git = true;
        icons = "auto";
      };

      htop.enable = true;

      k9s.enable = true;

      lazygit = {
        enable = true;
        settings = {
          customCommands = [
            {
              key = "a";
              context = "files";
              command = "git {{if .SelectedFile.HasUnstagedChanges}} add {{else}} reset {{end}} {{.SelectedFile.Name | quote}}";
              description = "Toggle file staged";
            }
            {
              key = "F";
              context = "files, remotes";
              command = ''
                git fetch --prune && \
                git for-each-ref --omit-empty --format="%(if:equals=[gone])%(upstream:track)%(then)%(refname:short)%(end)" refs/heads/ | \
                  xargs git branch --delete --force
              '';
              description = "Fetch (prune) and delete \"gone\" branches";
              output = "log";
            }
          ];

          git = {
            overrideGpg = true;
            pagers = [
              {
                colorArg = "always";
                pager = "delta --paging=never";
              }
            ];
            parseEmoji = true;
          };

          os = {
            editPreset = "nvim";
          };
        };
      };

      lesspipe.enable = true;

      pandoc.enable = true;

      ripgrep.enable = true;

      zoxide = {
        enable = true;
        enableZshIntegration = true;
      };
    };
  };

  linuxHomeManagerModule = {pkgs, ...}: {
    # netdiscover wrapper that automatically passes -R flag to skip root check.
    # The -R flag tells netdiscover to assume it has the required capabilities.
    # Capabilities are set by systemd service in os/linux/default.nix
    home.packages = [
      (pkgs.writeShellScriptBin "netdiscover" ''
        exec ${pkgs.netdiscover}/bin/netdiscover -R "$@"
      '')
    ];
  };
in {
  flake.modules."cli-tools" = {
    homeManagerModules = [homeManagerModule];
    os.linux.homeManagerModules = [linuxHomeManagerModule];
    os.nixos.homeManagerModules = [linuxHomeManagerModule];
  };
}
