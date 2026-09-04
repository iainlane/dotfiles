# Vendored from quadlet-nix, whose system-manager module is not yet released.
# The guts still come from the pinned input; only this module file is copied.
# Delete once it lands upstream and import `systemManagerModules.quadlet`.
{
  config,
  inputs,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mergeAttrsList mkIf getExe;

  cfg = config.virtualisation.quadlet;
  quadletUtils = import "${inputs.quadlet-nix}/utils.nix" {
    inherit pkgs lib;
    inherit (import (pkgs.path + "/nixos/lib/utils.nix") {inherit lib config pkgs;}) systemdUtils;
    inherit (cfg) podmanPackage;
    inherit (cfg) autoEscape;
  };
  quadletOptions = import "${inputs.quadlet-nix}/options.nix" {
    supportRootless = false;
    inherit lib quadletUtils;
  };
in {
  options.virtualisation.quadlet = quadletOptions.mkTopLevelOptions {
    podmanPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.podman;
      defaultText = lib.literalExpression "pkgs.podman";
      description = ''
        Podman package used in generated command lines, such as the network
        clean-up commands and podman auto-update.

        Note that quadlet file generation itself is done by the quadlet
        systemd generator installed on the host, typically as part of the
        host distribution's podman package.
      '';
    };
  };

  config = let
    allObjects = quadletOptions.getAllObjects cfg;
    enable = cfg.enable == true || (cfg.enable == null && allObjects != []);

    # Quadlet reads [Install] and writes the .wants symlink into its own
    # output directory, beside the unit it generates, so the symlink
    # resolves. system-manager starts system-manager.target on every
    # activation, so naming it starts services that are new since the last
    # one.
    autoStartTarget = p:
      if builtins.isString p._autoStart
      then p._autoStart
      else if p._autoStart
      then "system-manager.target"
      else null;

    quadletText = p:
      p._configText
      + lib.optionalString (autoStartTarget p != null) ''

        [Install]
        WantedBy=${autoStartTarget p}
      '';
  in
    mkIf enable {
      assertions = quadletOptions.mkAssertions [] cfg;
      warnings = quadletOptions.mkWarnings [] cfg;

      environment.etc = mergeAttrsList (
        map (p: {
          "containers/systemd/${p.ref}" = {
            text = quadletText p;
            mode = "0600";
          };
        })
        allObjects
      );

      # The main unit files are produced by the quadlet systemd generator at
      # daemon-reload, so the units are extended through drop-ins.
      # The config hash keeps the drop-in store path in sync with the quadlet
      # file, which makes system-manager restart the service on changes.
      systemd.services =
        mergeAttrsList (
          map (p: {
            ${p._serviceName} =
              {
                overrideStrategy = "asDropin";
                unitConfig.X-QuadletNixConfigHash = builtins.hashString "sha256" (quadletText p);
              }
              // p._overrides;
          })
          allObjects
        )
        // {
          # The host's podman units are not registered with the module system,
          # so complete unit files are generated for auto-update.
          podman-auto-update = mkIf cfg.autoUpdate.enable {
            description = "Podman auto-update service";
            documentation = ["man:podman-auto-update(1)"];
            serviceConfig = {
              Type = "oneshot";
              ExecStart = "${getExe cfg.podmanPackage} auto-update";
              ExecStartPost = "${getExe cfg.podmanPackage} image prune -f";
              TimeoutStartSec = "900s";
              TimeoutStopSec = "10s";
            };
          };
        };

      systemd.timers.podman-auto-update = mkIf cfg.autoUpdate.enable {
        description = "Podman auto-update timer";
        timerConfig = {
          OnCalendar = cfg.autoUpdate.calendar;
          Persistent = true;
        };
        wantedBy = ["timers.target"];
      };
    };
}
