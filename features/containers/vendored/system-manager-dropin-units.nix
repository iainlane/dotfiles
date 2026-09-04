# Vendored from system-manager, whose released systemd module ignores
# `overrideStrategy` and never reads `systemd.generators` or `systemd.shutdown`.
#
# A unit set to `asDropin` extends one whose main file comes from elsewhere,
# such as a systemd generator at runtime. system-manager writes every unit as a
# whole file under /etc/systemd/system, which takes precedence over
# /run/systemd/generator, so the generated unit is replaced by one carrying only
# the drop-in's settings and no ExecStart, which systemd refuses to load.
#
# The body tracks the upstream change so the two can be diffed. It is layered
# over the released module, so `systemd/system` is forced while the generators
# and shutdown entries are added to what is already in `environment.etc`.
# system-manager's own definition still warns about units declaring `aliases`,
# so that warning is not repeated here.
#
# Delete once system-manager does these itself.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.systemd;

  lndir = "${pkgs.buildPackages.lndir}/bin/lndir";

  substituteTarget = target:
    if target == "multi-user.target" || target == "timers.target"
    then "system-manager.target"
    else target;

  enabledUnits = lib.filterAttrs (_: unit: unit.enable) cfg.units;
  asDropinUnits = lib.filterAttrs (_: unit: unit.overrideStrategy == "asDropin") enabledUnits;
  asDropinIfExistsUnits =
    lib.filterAttrs (
      _: unit: unit.overrideStrategy == "asDropinIfExists"
    )
    enabledUnits;

  # A `.wants` entry has to be a symlink for systemd to take the dependency,
  # but its target is never read: the dependency comes from the entry's name.
  # A unit installed as a drop-in has no file beside the entry to point at, so
  # the entry points at the unit itself.
  wantsLinkTarget = name: unit:
    if unit.overrideStrategy == "asDropin"
    then "${unit.unit}/${name}"
    else "../${name}";

  # Contents of /etc/systemd/${dir}, gathered from the packages in
  # `systemd.packages` and from an attrset of links.
  hooks = dir: links:
    pkgs.runCommand dir {
      preferLocalBuild = true;
      allowSubstitutes = false;
      inherit (cfg) packages;
    } ''
      set -e
      mkdir -p $out
      for package in $packages
      do
        for hook in $package/lib/systemd/${dir}/*
        do
          ln -s $hook $out/
        done
      done
      ${lib.concatStrings (lib.mapAttrsToList (exec: target: "ln -s ${target} $out/${exec};\n") links)}
    '';
in {
  environment.etc = {
    "systemd/system-generators".source = hooks "system-generators" cfg.generators;
    "systemd/system-shutdown".source = hooks "system-shutdown" cfg.shutdown;

    "systemd/system".source =
      lib.mkForce
      (pkgs.runCommand "system-manager-units" {
          preferLocalBuild = true;
          allowSubstitutes = false;
          inherit (cfg) packages;
        } ''
          set -e
          mkdir -p $out

          # Symlink all units provided by the packages in systemd.packages.
          # Units are enabled through `wantedBy`, so .wants directories are
          # left out.

          # Filter duplicate directories
          declare -A unique_packages
          for k in $packages ; do unique_packages[$k]=1 ; done

          for i in ''${!unique_packages[@]}; do
            for fn in $i/etc/systemd/system/* $i/lib/systemd/system/*; do
              if ! [[ "$fn" =~ .wants$ ]]; then
                if [[ -d "$fn" ]]; then
                  targetDir="$out/$(basename "$fn")"
                  mkdir -p "$targetDir"
                  ${lndir} "$fn" "$targetDir"
                else
                  ln -s $fn $out/
                fi
              fi
            done
          done

          for i in ${toString (lib.mapAttrsToList (_n: v: v.unit) asDropinIfExistsUnits)}; do
            fn=$(basename $i/*)
            if [ -e $out/$fn ]; then
              if [ "$(readlink -f $i/$fn)" = /dev/null ]; then
                ln -sfn /dev/null $out/$fn
              else
                mkdir -p $out/$fn.d
                ln -s $i/$fn $out/$fn.d/overrides.conf
              fi
            else
              ln -fs $i/$fn $out/
            fi
          done

          # Symlink units defined by systemd.units which shall be treated
          # as drop-in file. Their main unit file comes from outside the
          # profile, such as a systemd generator, and a unit file in
          # /etc/systemd/system takes precedence over it.
          for i in ${toString (lib.mapAttrsToList (_n: v: v.unit) asDropinUnits)}; do
            fn=$(basename $i/*)
            mkdir -p $out/$fn.d
            ln -s $i/$fn $out/$fn.d/overrides.conf
          done

          ${lib.concatStrings (
            lib.mapAttrsToList (
              name: unit:
                lib.concatMapStrings (target: ''
                  mkdir -p $out/'${substituteTarget target}.wants'
                  ln -sfn '${wantsLinkTarget name unit}' $out/'${substituteTarget target}.wants'/
                '') (unit.wantedBy or [])
            )
            enabledUnits
          )}

          ${lib.concatStrings (
            lib.mapAttrsToList (
              name: unit:
                lib.concatMapStrings (target: ''
                  mkdir -p $out/'${substituteTarget target}.requires'
                  ln -sfn '${wantsLinkTarget name unit}' $out/'${substituteTarget target}.requires'/
                '') (unit.requiredBy or [])
            )
            enabledUnits
          )}
        '');
  };
}
