{
  pkgs,
  inputs,
  lib,
  ...
}: let
  # Catppuccin publishes every flavour's colours as one JSON document. Convert
  # them to Starship's palette format, which is a set of named attributes with
  # hex values.
  catppuccinFlavours =
    removeAttrs
    (lib.importJSON (inputs.catppuccin-palette + "/palette.json"))
    ["version"];

  catppuccinPalettes =
    lib.mapAttrs'
    (
      flavour: flavourData:
        lib.nameValuePair "catppuccin_${flavour}"
        (lib.mapAttrs (_name: colour: colour.hex) flavourData.colors)
    )
    catppuccinFlavours;

  mkSymbolModule = module: {format = "\$symbol";} // module;

  simpleSymbolModules = {
    bun = {
      symbol = "🥟";
      detect_files = [
        ".bun-version"
        "bun.toml"
        "bun.lock"
        "bun.lockb"
      ];
    };
    c = {
      symbol = "";
    };
    dart = {
      symbol = "";
    };
    dotnet = {
      symbol = "";
    };
    elixir = {
      symbol = "";
    };
    elm = {
      symbol = "";
    };
    erlang = {
      symbol = "";
    };
    golang = {
      symbol = "";
    };
    haskell = {
      symbol = "󰲒";
    };
    haxe = {
      symbol = "";
    };
    java = {
      symbol = "󰬷";
    };
    julia = {
      symbol = "";
    };
    kotlin = {
      symbol = "";
    };
    lua = {
      symbol = "";
    };
    nim = {
      symbol = "";
    };
    nodejs = {
      symbol = "";
      detect_files = [
        "package.json"
        ".node-version"
        "!bunfig.toml"
        "!bun.lockb"
        "!bun.lock"
      ];
    };
    perl = {
      symbol = "";
    };
    php = {
      symbol = "󰌟";
    };
    python = {
      symbol = "";
    };
    rlang = {
      symbol = "";
    };
    ruby = {
      symbol = "";
    };
    rust = {
      symbol = "";
    };
    scala = {
      symbol = "";
    };
    swift = {
      symbol = "";
    };
    zig = {
      symbol = "";
    };
  };

  languageSymbols = lib.mapAttrs (_: mkSymbolModule) simpleSymbolModules;

  languageNames = lib.concatMapStrings (name: "\$${name}") (builtins.attrNames simpleSymbolModules);

  osIcons = {
    AlmaLinux = {
      icon = "";
      color = "text";
    };
    Alpine = {
      icon = "";
      color = "blue";
    };
    Amazon = {
      icon = "";
      color = "peach";
    };
    Android = {
      icon = "";
      color = "green";
    };
    Arch = {
      icon = "󰣇";
      color = "sapphire";
    };
    Artix = {
      icon = "";
      color = "sapphire";
    };
    CentOS = {
      icon = "";
      color = "mauve";
    };
    Debian = {
      icon = "";
      color = "red";
    };
    DragonFly = {
      icon = "";
      color = "teal";
    };
    EndeavourOS = {
      icon = "";
      color = "mauve";
    };
    Fedora = {
      icon = "";
      color = "blue";
    };
    FreeBSD = {
      icon = "";
      color = "red";
    };
    Garuda = {
      icon = "";
      color = "sapphire";
    };
    Gentoo = {
      icon = "";
      color = "lavender";
    };
    Illumos = {
      icon = "";
      color = "peach";
    };
    Kali = {
      icon = "";
      color = "blue";
    };
    Linux = {
      icon = "";
      color = "yellow";
    };
    Macos = {
      icon = "";
      color = "text";
    };
    Manjaro = {
      icon = "";
      color = "green";
    };
    Mint = {
      icon = "󰣭";
      color = "teal";
    };
    NixOS = {
      icon = "";
      color = "sky";
    };
    OpenBSD = {
      icon = "";
      color = "yellow";
    };
    Pop = {
      icon = "";
      color = "sapphire";
    };
    Raspbian = {
      icon = "";
      color = "maroon";
    };
    RedHatEnterprise = {
      icon = "";
      color = "red";
    };
    Redhat = {
      icon = "";
      color = "red";
    };
    RockyLinux = {
      icon = "";
      color = "green";
    };
    SUSE = {
      icon = "";
      color = "green";
    };
    Solus = {
      icon = "";
      color = "blue";
    };
    Ubuntu = {
      icon = "";
      color = "peach";
    };
    Unknown = {
      icon = "";
      color = "text";
    };
    Void = {
      icon = "";
      color = "green";
    };
    Windows = {
      icon = "󰖳";
      color = "sky";
    };
    openSUSE = {
      icon = "";
      color = "green";
    };
  };

  osSymbols =
    lib.mapAttrs
    (_name: entry: "[${entry.icon}](fg:${entry.color} bg:surface1)")
    osIcons;
in {
  programs.starship = {
    enable = true;

    # A fork of starship with a fix for the width of Unicode characters.
    package = pkgs.starship.overrideAttrs (prevAttrs: {
      src = inputs.starship-custom;

      # Building the vendor directory from the fork's own `Cargo.lock`
      # replaces the one nixpkgs fetches with `cargoHash`, so that hash is
      # unused here and does not have to be updated when the fork moves.
      cargoDeps = pkgs.rustPlatform.importCargoLock {
        lockFile = "${inputs.starship-custom}/Cargo.lock";
      };

      # The time module uses jiff, which reads timezone data from the
      # system. The build sandbox has none, so the tests fail without this.
      env = (prevAttrs.env or {}) // {TZDIR = "${pkgs.tzdata}/share/zoneinfo";};
    });

    enableZshIntegration = true;

    settings =
      languageSymbols
      // {
        add_newline = false;
        command_timeout = 1000;
        # A powerline-style prompt of coloured segments, from left to right:
        # battery, os, user/host, languages, git, shell state.
        format = lib.concatStrings [
          "[](surface1)"
          "[\${battery}\${os}](fg:text bg:surface1)"
          "[](fg:surface1 bg:surface2)"
          "[\$sudo\$username](fg:text bg:surface2)"
          "[](fg:surface2 bg:overlay0)"
          "[\$hostname](fg:text bg:overlay0)"
          "[](fg:overlay0 bg:mauve)"
          "[( ${languageNames})( \$package)( \$git_branch)](fg:base bg:mauve)"
          "[](fg:mauve bg:peach)"
          "[( \${git_state}\${git_status})](fg:base bg:peach)"
          "[](fg:peach bg:yellow)"
          "[( \$container\$direnv\$nix_shell\$cmd_duration\$jobs\$shlvl)](fg:base bg:yellow)"
          # After a failed command `$status` expands to one of the symbols
          # below, red on pink, and the separator drawn in front of it turns
          # the yellow section into the pink one. After a successful command
          # `$status` is empty and nothing here is drawn, so `character`
          # closes the yellow section.
          "[([](fg:yellow bg:pink) \$status)](fg:text bg:pink)"
          # `character` draws the final prompt character, pink after a failed
          # command and teal after a successful one. Its success symbol also
          # closes the yellow section, which `$status` left open.
          "\$character"
        ];
        right_format = "[](fg:blue)[\$directory](fg:base bg:blue)";
        palette = "catppuccin_macchiato";

        battery = {
          format = "\$symbol";
          display = [
            {
              threshold = 100;
            }
          ];
        };

        character = {
          disabled = false;
          error_symbol = "[](fg:pink) ";
          format = "\$symbol";
          success_symbol = "[](fg:yellow bg:teal)[](fg:teal) ";
        };

        cmd_duration = {
          format = " \$duration";
          min_time = 2500;
          min_time_to_notify = 60000;
          show_notifications = false;
        };

        container = {
          format = "\$symbol \$name";
          symbol = "󱋩";
        };

        # Drawn by `right_format`, at the right-hand end of the line.
        directory = {
          fish_style_pwd_dir_length = 1;
          read_only = " 󰈈";
          read_only_style = "fg:red bg:blue";
          repo_root_style = "\$style";
          before_repo_root_style = "fg:dimmed bg:blue";
          style = "fg:base bg:blue";
          truncation_length = 3;
        };

        direnv = {
          allowed_msg = "";
          denied_msg = "";
          disabled = false;
          format = "\$loaded";
          loaded_msg = "󰐍";
          not_allowed_msg = "";
          symbol = "";
          unloaded_msg = "󰙧";
        };

        git_branch = {
          format = "\$symbol \$branch";
          symbol = "";
        };

        git_state = {
          disabled = false;
          format = "\$state (\${progress_current}/\${progress_total}) ";
        };

        git_status = {
          format = "\$all_status\$ahead_behind";
          ahead = "⇡\${count}";
          diverged = "⇕⇡\${ahead_count}⇣\${behind_count}";
          behind = "⇣\${count}";
          up_to_date = "✔︎";
        };

        hostname = {
          disabled = false;
          format = "[\$hostname](\$style)[\$ssh_symbol](fg:maroon bg:overlay0)";
          ssh_only = false;
          ssh_symbol = " 󰖈";
          style = "fg:red bg:overlay0";
        };

        jobs = {
          format = "\$symbol \$number";
          symbol = "󰣖";
        };

        nix_shell = {
          format = "\$symbol";
          symbol = "󱄅";
        };

        os = {
          disabled = false;

          symbols = osSymbols;
        };

        package = {
          format = "\$version";
          version_format = "\$raw";
        };

        palettes = catppuccinPalettes;

        shlvl = {
          disabled = false;
          format = "[ \$symbol](\$style)";
          repeat = false;
          style = "fg:surface1 bg:yellow";
          symbol = "󱆃";
          threshold = 3;
        };

        status = {
          disabled = false;
          format = "\$symbol";
          map_symbol = true;
          not_executable_symbol = "[ \$common_meaning](fg:red bg:pink)";
          not_found_symbol = "[󰩌 \$common_meaning](fg:red bg:pink)";
          sigint_symbol = "[ \$signal_name](fg:red bg:pink)";
          signal_symbol = "[⚡ \$signal_name](fg:red bg:pink)";
          style = "";
          success_symbol = "";
          symbol = "[ \$status](fg:red bg:pink)";
        };

        sudo = {
          disabled = false;
          format = "[\$symbol](\$style)";
          style = "fg:rosewater bg:surface2";
          symbol = "󰌋";
        };

        time = {
          disabled = true;
        };

        username = {
          format = "[\$user](\$style)";
          show_always = true;
          style_root = "fg:red bg:surface2";
          style_user = "fg:green bg:surface2";
          aliases = {
            root = "󰱯";
          };
        };
      };
  };
}
