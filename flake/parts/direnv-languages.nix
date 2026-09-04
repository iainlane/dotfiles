# The per-language fragments that make up a project's direnv shell, and the
# helper that merges them.
#
# This is flake-level data, read by the project-shell helper in
# `lib/projects.nix`, not configuration for any host, so it lives beside the
# other flake parts.
{
  config,
  lib,
  ...
}: let
  inherit (lib) mkOption types;

  # A language fragment is a function `pkgs -> attrset` returning a partial
  # mkShell argument set. The submodule mirrors the shape used by
  # `flake.features`: a base value plus an `os.<name>` branch that overlays
  # it for that platform.
  shellOption = mkOption {
    type = types.nullOr (types.functionTo types.attrs);
    default = null;
    description = ''
      Function `pkgs -> attrset` returning mkShell arguments such as
      `packages`, `shellHook`, or environment variables.
    '';
  };

  languageSubmodule = types.submodule {
    options = {
      shell = shellOption;
      os = mkOption {
        type = types.attrsOf (types.submodule {options.shell = shellOption;});
        default = {};
        description = ''
          Per-OS shell fragment overlays, keyed by the host platform (`linux`,
          `darwin`, ...). Merged into the base `shell` when building for that
          platform.
        '';
      };
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

  applyShell = pkgs: fn:
    if fn == null
    then {}
    else fn pkgs;

  fragmentFor = pkgs: os: name: let
    lang = config.flake.direnvLanguages.${name};
    base = applyShell pkgs lang.shell;
    overlay = applyShell pkgs (lib.attrByPath ["os" os "shell"] null lang);
  in
    mergeShellAttrs base overlay;
in {
  options.flake = {
    direnvLanguages = mkOption {
      type = types.attrsOf languageSubmodule;
      default = {};
      description = ''
        Per-language fragments contributed to direnv shells. Each entry has
        a base `shell` function and may carry per-OS overlays under
        `os.<name>.shell`. Features compose these by listing language names
        on a project definition rather than replicating shell glue.
      '';
    };

    mkLanguageShell = mkOption {
      type = types.unspecified;
      readOnly = true;
      description = ''
        Helper `pkgs -> os -> [name] -> attrs` that merges `direnvLanguages`
        fragments (and any matching `os.<name>` overlay) for a list of
        language names into a single mkShell argument set. The `os` is the
        kernel name passed in by the per-system caller, so the resolver does
        no platform detection of its own.
      '';
    };
  };

  config.flake = {
    direnvLanguages = {
      go.shell = pkgs: let
        # Pin the shell's Go to the one nixpkgs used to build golangci-lint, so
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
      };

      rust.shell = pkgs: let
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
      };

      python.shell = pkgs: {
        packages = with pkgs; [
          python3
          ruff
          pyright
        ];
      };

      typescript = {
        shell = pkgs: {
          packages = with pkgs; [
            bun
            corepack
            deno
            nodejs
            pnpm
            typescript
            pkgs."typescript-language-server"
          ];
        };

        # Playwright's prebuilt Chromium is a glibc-built binary that runs
        # under nix-ld on NixOS. The system-wide nix-ld config only ships
        # libraries that everything needs; everything else must come through
        # `NIX_LD_LIBRARY_PATH` in the shell that launches the browser, so
        # prepend the Chromium runtime libraries here for any direnv that opts
        # into the typescript language.
        os.linux.shell = pkgs: let
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
        };
      };

      lua.shell = pkgs: {
        packages = with pkgs; [
          lua
          luarocks
          lua-language-server
        ];
      };
    };

    mkLanguageShell = pkgs: os: names:
      lib.foldl'
      mergeShellAttrs
      {}
      (map (name: fragmentFor pkgs os name) names);
  };
}
