{
  inputs,
  pkgs,
  system,
  ...
}: {
  imports = [
    ./fzf.nix
    ./linux.nix
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
          paging = {
            colorArg = "always";
            pager = "delta --paging=never";
          };
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
}
