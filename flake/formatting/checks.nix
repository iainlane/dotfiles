{inputs}: {
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
  checks = {
    statix =
      pkgs.runCommandLocal "statix-check" {}
      ''
        set -e

        cd ${lib.escapeShellArg inputs.self}
        ${lib.getExe pkgs.statix} check ${statixIgnoreArgs} .

        touch $out
      '';
    treefmt = config.treefmt.build.check inputs.self;

    zsh-tooling =
      pkgs.runCommandLocal "zsh-tooling" {
        nativeBuildInputs = [pkgs.diffutils pkgs.zsh];
      } ''
        mkdir -p features/base/zsh
        touch flake.nix
        script=features/base/zsh/probe.zsh

        printf 'greet(){\nprint -r -- ok\n}\n' >"$script"
        ${lib.getExe config.treefmt.build.wrapper} --no-cache "$script"
        printf 'greet() {\n\tprint -r -- ok\n}\n' >expected.zsh
        diff -u expected.zsh "$script"

        printf '%s\n' 'example_f() { local ZSH_VERSION=1; }' >"$script"
        zsh -fn "$script"
        if ${lib.getExe config.treefmt.build.wrapper} --no-cache "$script" >diagnostics 2>&1; then
          echo "Zsh linting accepted a shadowed shell parameter" >&2
          exit 1
        fi
        grep -F 'compat/special-param-shadow' diagnostics

        touch "$out"
      '';
  };
}
