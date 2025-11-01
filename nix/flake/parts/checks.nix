{inputs, ...}:
# Configure formatting and linting checks for the project.
# We use treefmt as a formatter multiplexer for `nix fmt`.
{
  imports = [inputs.treefmt-nix.flakeModule];

  perSystem = {pkgs, ...}: let
    inherit (pkgs) lib;
    treefmtConfig = {
      projectRootFile = "flake.nix";
      settings.global.excludes = ["**/lazy-lock.json"];
      programs = {
        alejandra.enable = true;
        deadnix.enable = true;
        statix.enable = true;
        shfmt.enable = true;
        stylua.enable = true;
        prettier.enable = true;
        mdformat.enable = true;
      };
    };

    statixIgnoreArgs =
      lib.concatMapStringsSep " "
      (pattern: "--ignore ${lib.escapeShellArg pattern}")
      (treefmtConfig.settings.global.excludes or []);
    statixBinary = lib.getExe pkgs.statix;
  in {
    treefmt = treefmtConfig;
    checks.statix =
      pkgs.runCommandLocal "statix-check" {}
      ''
        set -e

        cd ${lib.escapeShellArg inputs.self}
        ${statixBinary} check ${statixIgnoreArgs} .

        touch $out
      '';
  };
}
