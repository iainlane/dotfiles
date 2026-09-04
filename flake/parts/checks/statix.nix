{inputs, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    inherit (pkgs) lib;

    statixIgnoreArgs =
      lib.concatMapStringsSep " "
      (pattern: "--ignore ${lib.escapeShellArg pattern}")
      config.treefmt.settings.excludes;
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
