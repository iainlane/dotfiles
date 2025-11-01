{
  pkgs,
  inputs,
  lib,
  ...
}: let
  mkSymbolModule = module: let
    attrs = removeAttrs module ["symbol"];
  in
    {
      format = "\$symbol";
      inherit (module) symbol;
    }
    // attrs;

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

  osSymbols = lib.listToAttrs (
    map
    (entry: {
      inherit (entry) name;
      value = "[${entry.icon}](fg:${entry.color} bg:surface1)";
    })
    [
      {
        name = "AlmaLinux";
        icon = "";
        color = "text";
      }
      {
        name = "Alpine";
        icon = "";
        color = "blue";
      }
      {
        name = "Amazon";
        icon = "";
        color = "peach";
      }
      {
        name = "Android";
        icon = "";
        color = "green";
      }
      {
        name = "Arch";
        icon = "󰣇";
        color = "sapphire";
      }
      {
        name = "Artix";
        icon = "";
        color = "sapphire";
      }
      {
        name = "CentOS";
        icon = "";
        color = "mauve";
      }
      {
        name = "Debian";
        icon = "";
        color = "red";
      }
      {
        name = "DragonFly";
        icon = "";
        color = "teal";
      }
      {
        name = "EndeavourOS";
        icon = "";
        color = "mauve";
      }
      {
        name = "Fedora";
        icon = "";
        color = "blue";
      }
      {
        name = "FreeBSD";
        icon = "";
        color = "red";
      }
      {
        name = "Garuda";
        icon = "";
        color = "sapphire";
      }
      {
        name = "Gentoo";
        icon = "";
        color = "lavender";
      }
      {
        name = "Illumos";
        icon = "";
        color = "peach";
      }
      {
        name = "Kali";
        icon = "";
        color = "blue";
      }
      {
        name = "Linux";
        icon = "";
        color = "yellow";
      }
      {
        name = "Macos";
        icon = "";
        color = "text";
      }
      {
        name = "Manjaro";
        icon = "";
        color = "green";
      }
      {
        name = "Mint";
        icon = "󰣭";
        color = "teal";
      }
      {
        name = "NixOS";
        icon = "";
        color = "sky";
      }
      {
        name = "OpenBSD";
        icon = "";
        color = "yellow";
      }
      {
        name = "Pop";
        icon = "";
        color = "sapphire";
      }
      {
        name = "Raspbian";
        icon = "";
        color = "maroon";
      }
      {
        name = "RedHatEnterprise";
        icon = "";
        color = "red";
      }
      {
        name = "Redhat";
        icon = "";
        color = "red";
      }
      {
        name = "RockyLinux";
        icon = "";
        color = "green";
      }
      {
        name = "SUSE";
        icon = "";
        color = "green";
      }
      {
        name = "Solus";
        icon = "";
        color = "blue";
      }
      {
        name = "Ubuntu";
        icon = "";
        color = "peach";
      }
      {
        name = "Unknown";
        icon = "";
        color = "text";
      }
      {
        name = "Void";
        icon = "";
        color = "green";
      }
      {
        name = "Windows";
        icon = "󰖳";
        color = "sky";
      }
      {
        name = "openSUSE";
        icon = "";
        color = "green";
      }
    ]
  );
in {
  programs.starship = {
    enable = true;

    # Build a custom starship to include a Unicode wide character fix
    package = pkgs.starship.overrideAttrs (_oldAttrs: {
      src = inputs.starship-custom;
      cargoDeps = pkgs.rustPlatform.importCargoLock {
        lockFile = "${inputs.starship-custom}/Cargo.lock";
      };
    });

    enableZshIntegration = true;

    settings =
      languageSymbols
      // {
        add_newline = false;
        command_timeout = 1000;
        # Custom prompt format with colored segments (powerline-style)
        # Segments from left to right: battery → os → user/host →
        # languages → git → shell state
        format = lib.concatStrings [
          "[](surface1)"
          "[\${battery}\${os}](fg:white bg:surface1)"
          "[](fg:surface1 bg:surface2)"
          "[\$sudo\$username](bg:surface2)"
          "[](fg:surface2 bg:overlay0)"
          "[\$hostname](bg:overlay0)"
          "[](fg:overlay0 bg:mauve)"
          "[( ${languageNames})( \$package)( \$git_branch)](fg:base bg:mauve)"
          "[](fg:mauve bg:peach)"
          "[( \${git_state}\${git_status})](fg:base bg:peach)"
          "[](fg:peach bg:yellow)"
          "[( \$container\$direnv\$nix_shell\$cmd_duration\$jobs\$shlvl)](fg:base bg:yellow)"
          # If $status is non-empty, this means the last command failed, so
          # we'll be showing an error status segment following this in red.
          # Otherwise, show a success status segment in yellow.
          "[([](fg:yellow bg:pink) \$status)](bg:pink)"
          # The final prompt character is either pink (error) or teal (success).
          # But we also need to draw the end of the yellow section if `status`
          # didn't do that just above. We handle that in `character`.
          "\$character"
        ];
        right_format = "[](fg:blue)[\$directory](fg:base bg:blue)";
        palette = "catppuccin_mocha";

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

        # This is on the RHS
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

        palettes.catppuccin_mocha = {
          base = "#1e1e2e";
          blue = "#89b4fa";
          crust = "#11111b";
          flamingo = "#f2cdcd";
          green = "#a6e3a1";
          lavender = "#b4befe";
          mantle = "#181825";
          maroon = "#eba0ac";
          mauve = "#cba6f7";
          overlay0 = "#6c7086";
          overlay1 = "#7f849c";
          overlay2 = "#9399b2";
          peach = "#fab387";
          pink = "#f5c2e7";
          red = "#f38ba8";
          rosewater = "#f5e0dc";
          sapphire = "#74c7ec";
          sky = "#89dceb";
          subtext0 = "#a6adc8";
          subtext1 = "#bac2de";
          surface0 = "#313244";
          surface1 = "#45475a";
          surface2 = "#585b70";
          teal = "#94e2d5";
          text = "#cdd6f4";
          yellow = "#f9e2af";
        };

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
