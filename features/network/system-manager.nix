{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.dotfiles.network;

  inherit (cfg.systemd.network) units;

  reloadUnit = "networkctl-reload";
in {
  config = lib.mkMerge [
    {
      # Keep the address assertion outside the link-unit condition: services
      # can request lanAddress on a host that declares no links.
      assertions = [
        {
          assertion = lib.length cfg.privateAddresses == 1;
          message = ''
            dotfiles.network.lanAddress is the host's own address on the LAN:
            the single private IPv4 address configured on the networks under
            dotfiles.network.systemd.network. They have ${
              if cfg.privateAddresses == []
              then "none"
              else "${toString (lib.length cfg.privateAddresses)}: ${lib.concatStringsSep ", " cfg.privateAddresses}"
            }.

            A feature that publishes a container port binds it to that
            address and composes this feature to read it, so a host running
            one of those services describes its links under
            dotfiles.network.systemd.network even if something else already
            configures them.
          '';
        }
      ];
    }

    (lib.mkIf (units != {}) {
      environment.etc =
        lib.mapAttrs' (
          name: unit:
            lib.nameValuePair "systemd/network/${name}" {source = "${unit.unit}/${name}";}
        )
        units;

      # systemd-networkd applies a changed .network file only when it is told
      # to re-read the directory. The unit runs on every activation and is
      # ordered after the files are in place, so the links follow the
      # configuration without a reboot.
      systemd.services.${reloadUnit} = {
        description = "Reload systemd-networkd's link configuration";
        wantedBy = ["system-manager.target"];
        after = ["systemd-networkd.service"];
        restartTriggers = lib.mapAttrsToList (name: unit: "${unit.unit}/${name}") units;

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${pkgs.systemd}/bin/networkctl reload";
          # At boot this can race systemd-networkd's own startup.
          Restart = "on-failure";
          RestartSec = "2s";
        };
      };
    })
  ];
}
