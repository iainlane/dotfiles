{inputs, ...}: {
  perSystem = {pkgs, ...}: let
    inherit (pkgs) lib;
    treefmtConfig = import ../treefmt-config.nix {inherit pkgs;};
    statixIgnoreArgs =
      lib.concatMapStringsSep " "
      (pattern: "--ignore ${lib.escapeShellArg pattern}")
      (treefmtConfig.settings.global.excludes or []);
  in {
    checks.statix =
      pkgs.runCommandLocal "statix-check" {}
      ''
        set -e

        cd ${lib.escapeShellArg inputs.self}
        ${lib.getExe pkgs.statix} check ${statixIgnoreArgs} .

        touch $out
      '';
  };
}
