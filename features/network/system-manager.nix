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
  config = lib.mkIf (units != {}) {
    assertions = [
      {
        assertion = lib.length cfg.privateAddresses == 1;
        message = ''
          dotfiles.network.lanAddress is the host's own address on the LAN,
          and the networks under dotfiles.network.systemd.network carry
          ${
            if cfg.privateAddresses == []
            then "no private IPv4 address"
            else "${toString (lib.length cfg.privateAddresses)} of them: ${lib.concatStringsSep ", " cfg.privateAddresses}"
          }.
        '';
      }
    ];

    environment.etc =
      lib.mapAttrs' (
        name: unit:
          lib.nameValuePair "systemd/network/${name}" {source = "${unit.unit}/${name}";}
      )
      units;

    # systemd-networkd applies a changed .network file only when it is told to
    # re-read the directory. The unit runs on every activation and is ordered
    # after the files are in place, so the links follow the configuration
    # without a reboot.
    systemd.services.${reloadUnit} = {
      description = "Reload systemd-networkd's link configuration";
      wantedBy = ["system-manager.target"];
      after = ["systemd-networkd.service"];
      restartTriggers = lib.mapAttrsToList (name: unit: "${unit.unit}/${name}") units;

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${pkgs.systemd}/bin/networkctl reload";
      };
    };
  };
}
