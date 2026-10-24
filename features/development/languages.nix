# The per-language fragments that make up a project's direnv shell, and the
# helper that merges them.
#
# This is flake-level data, read by the project-shell helper in
# `lib/projects.nix`, not configuration for any host, so it lives beside the
# other flake parts.
{
  config,
  lib,
  featureResolver,
  ...
}: let
  inherit (lib) mkOption types;

  fragmentType = lib.mkOptionType {
    name = "shellFragment";
    description = "shell function or conditional shell fragments";
    check = value: lib.isFunction value || (featureResolver.isConditional value && lib.all fragmentType.check value.includes);
    merge = lib.mergeOneOption;
  };
  languageSubmodule = types.submodule {
    options.fragments = mkOption {
      type = types.listOf fragmentType;
      default = [];
      description = "Conditional functions returning mkShell arguments.";
    };
  };

  # Combine two mkShell argument sets, concatenating list-valued and
  # string-valued attributes that need accumulation across languages
  # (`packages`, `shellHook`) and letting later fragments win on everything
  # else.
  mergeShellAttrs = a: b:
    a
    // b
    // {
      packages = (a.packages or []) ++ (b.packages or []);
      shellHook = lib.concatStringsSep "\n" (
        lib.filter (s: s != "") [
          (a.shellHook or "")
          (b.shellHook or "")
        ]
      );
    };
in {
  options.dotfiles = {
    direnvLanguages = mkOption {
      type = types.attrsOf languageSubmodule;
      default = {};
      description = ''
        Per-language fragments contributed to direnv shells. Each entry has
        a `fragments` list of shell functions and conditional groups. A feature
        composes these by listing language names on a project definition.
      '';
    };
  };

  config._module.args.mkLanguageShell = pkgs: platform: names:
    lib.foldl' mergeShellAttrs {} (map (fragment: fragment pkgs)
      (featureResolver.select {inherit platform;} (lib.concatMap (name: config.dotfiles.direnvLanguages.${name}.fragments) names)));

  config.dotfiles = {
    direnvLanguages = {
      go.fragments = [
        (pkgs: let
          # Use the Go toolchain from golangci-lint so
          # the linter's bundled `golang.org/x/tools` never lags behind the
          # toolchain that runs `go list`.
          inherit (pkgs.golangci-lint) go;
        in {
          packages = [
            go
            pkgs.gopls
            pkgs.gotools
            pkgs.golangci-lint
            pkgs.delve
          ];
        })
      ];

      rust.fragments = [
        (pkgs: let
          inherit (pkgs) fenix;
          stableToolchain = fenix.stable.withComponents [
            "cargo"
            "clippy"
            "rust-src"
            "rustc"
            "rustfmt"
          ];
          nightlyRustfmt = fenix.complete.withComponents ["rustfmt"];
        in {
          packages = [
            stableToolchain
            nightlyRustfmt
            fenix.rust-analyzer
          ];
        })
      ];

      python.fragments = [
        (pkgs: {
          packages = with pkgs; [
            python3
            ruff
            pyright
          ];
        })
      ];

      typescript = {
        fragments = [
          (pkgs: {
            packages = with pkgs; [
              bun
              corepack
              deno
              nodejs
              pnpm
              typescript
              pkgs."typescript-language-server"
            ];
          })

          # Playwright's prebuilt Chromium is a glibc-built binary that runs
          # under nix-ld on NixOS. The system-wide nix-ld config only ships
          # libraries that everything needs; everything else must come through
          # `NIX_LD_LIBRARY_PATH` in the shell that launches the browser, so
          # prepend the Chromium runtime libraries here for any direnv that opts
          # into the typescript language.
          (featureResolver.when featureResolver.isLinux [
            (pkgs: let
              chromiumLibraries = with pkgs; [
                alsa-lib
                at-spi2-core
                cairo
                cups
                dbus
                expat
                gdk-pixbuf
                glib
                gtk3
                libdrm
                libgbm
                libx11
                libxcb
                libxcomposite
                libxdamage
                libxext
                libxfixes
                libxkbcommon
                libxrandr
                libxshmfence
                nspr
                nss
                pango
                systemd
              ];
            in {
              shellHook = ''
                export NIX_LD_LIBRARY_PATH="${lib.makeLibraryPath chromiumLibraries}''${NIX_LD_LIBRARY_PATH:+:$NIX_LD_LIBRARY_PATH}"
              '';
            })
          ])
        ];
      };

      lua.fragments = [
        (pkgs: {
          packages = with pkgs; [
            lua
            luarocks
            lua-language-server
          ];
        })
      ];
    };
  };
}
