{inputs, ...}:
# Configure formatting and linting checks for the project. Nix flakes can output
# `formatter.<system>`. This is a single output - `treefmt` is a multiplexer that
# handles invoking formatters/linters based on file type.
{
  imports = [inputs.treefmt-nix.flakeModule];

  perSystem = {pkgs, ...}: let
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
        # We use `markdownlint-cli` instead of `mdformat`.
        mdformat.enable = false;
        nixf-diagnose = {
          enable = true;
          variableLookup = true;
        };
        shellcheck = {
          enable = true;
          severity = "style";
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

        # Custom markdownlint formatter
        formatter.markdownlint = {
          command = lib.getExe pkgs.markdownlint-cli;
          options = ["--fix" "--"];
          includes = ["*.md"];
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
