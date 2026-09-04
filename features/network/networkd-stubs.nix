# Declarations for the options NixOS's networkd module reads and defines
# outside `systemd.network`.
#
# The module is evaluated on its own so that only the rendered link, device and
# network files reach the host: its service, user and resolver definitions
# belong to a NixOS system, and these hosts run the distribution's own
# systemd-networkd. Nothing declared here is read back.
#
# The stage 1 half is declared as well. Its definitions are all under
# `mkIf config.boot.initrd.systemd.enable`, which stays false, but the module
# system checks that an option exists before it discharges the condition.
{
  lib,
  pkgs,
  ...
}: let
  ignored = lib.mkOption {
    type = lib.types.raw;
    default = {};
    description = "Ignored; declared so NixOS's networkd module evaluates here.";
  };

  ignoredFlag = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = "Ignored; declared so NixOS's networkd module evaluates here.";
  };

  systemdPackage = lib.mkOption {
    type = lib.types.package;
    default = pkgs.systemd;
    defaultText = lib.literalExpression "pkgs.systemd";
    description = ''
      systemd package the network files are rendered against. Its unit
      definitions are what `systemd-analyze verify` checks them with.
    '';
  };
in {
  options = {
    assertions = ignored;

    boot.initrd = {
      kernelModules = ignored;

      network = {
        enable = ignoredFlag;
        flushBeforeStage2 = ignoredFlag;
        udhcpc = {
          enable = ignoredFlag;
          extraArgs = ignored;
        };
      };

      systemd = {
        enable = ignoredFlag;
        additionalUpstreamUnits = ignored;
        contents = ignored;
        dbus.enable = ignoredFlag;
        groups = ignored;
        package = systemdPackage;
        services = ignored;
        sockets = ignored;
        storePaths = ignored;
        users = ignored;
      };
    };

    environment.etc = ignored;

    networking.iproute2 = ignored;

    services.resolved.enable = ignoredFlag;

    systemd = {
      additionalUpstreamSystemUnits = ignored;
      package = systemdPackage;
      services = ignored;
      sockets = ignored;
    };

    users.users = ignored;
  };
}
