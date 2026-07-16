{inputs, ...}:
# Configure formatting and linting checks for the project. Nix flakes can output
# `formatter.<system>`. This is a single output - `treefmt` is a multiplexer that
# handles invoking formatters/linters based on file type.
{
  imports = [inputs.treefmt-nix.flakeModule];

  perSystem = {config, ...}: let
    inherit (config._module.args) pkgs;
    inherit (pkgs) lib;

    statixIgnoreArgs =
      lib.concatMapStringsSep " "
      (pattern: "--ignore ${lib.escapeShellArg pattern}")
      (treefmtConfig.settings.global.excludes or []);
    statixBinary = lib.getExe pkgs.statix;

    treefmtConfig = {
      programs = {
        actionlint.enable = true;
        alejandra.enable = true;
        deadnix.enable = true;
        # Markdown is linted by the custom `markdownlint` formatter below.
        mdformat.enable = false;
        nixf-diagnose = {
          enable = true;
          variableLookup = true;
        };
        shellcheck = {
          enable = true;
          severity = "style";
          external-sources = true;
          source-path = "SCRIPTDIR";
        };
        shfmt = {
          enable = true;
          useEditorConfig = true;
        };
        statix.enable = true;
        stylua.enable = true;
        prettier = {
          enable = true;
          settings = {
            proseWrap = "always";
          };
        };
        zizmor.enable = true;
      };

      projectRootFile = "flake.nix";

      settings = {
        global.excludes = ["**/lazy-lock.json"];

        formatter = {
          zizmor.options = ["--persona" "pedantic"];

          # Custom markdownlint formatter
          markdownlint = {
            command = lib.getExe pkgs.markdownlint-cli2;
            options = ["--fix" "--"];
            includes = ["*.md"];
          };

          # Strict Lua linting. Globals are limited to known Neovim/LazyVim runtime
          # symbols that are intentionally available at runtime.
          luacheck = {
            command = lib.getExe pkgs.luaPackages.luacheck;
            options = [
              "--globals"
              "vim"
              "LazyVim"
              "Snacks"
              "--no-max-line-length"
              "--"
            ];
            includes = ["*.lua"];
          };
        };
      };
    };
  in {
    checks.statix =
      pkgs.runCommandLocal "statix-check" {}
      ''
        set -e

        cd ${lib.escapeShellArg inputs.self}
        ${statixBinary} check ${statixIgnoreArgs} .

        touch $out
      '';

    treefmt = treefmtConfig;
  };
}
