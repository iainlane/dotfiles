# Adapter for nixos/modules/virtualisation/podman and its containers module.
#
# Imports the upstream NixOS modules so `virtualisation.podman` and
# `virtualisation.containers` mean the same here as they do on NixOS: the
# podman package and socket, /etc/containers/policy.json, registries.conf,
# storage.conf and containers.conf.
#
# Defines the options those modules reference that system-manager lacks, each
# saying in its description what happens to what it is given.
#
# This is shaped to be proposed to system-manager as
# nix/modules/upstream/nixpkgs/virtualisation/podman.nix.
{
  config,
  lib,
  nixosModulesPath,
  ...
}: {
  imports = [
    (nixosModulesPath + "/virtualisation/containers.nix")
    (nixosModulesPath + "/virtualisation/podman")
    # podman's networkSocket.server = "ghostunnel" configures this module.
    (nixosModulesPath + "/services/networking/ghostunnel.nix")
  ];

  options = {
    systemd.user.sockets = lib.mkOption {
      type = lib.types.attrs;
      default = {};
      internal = true;
      description = ''
        Podman defines a per-user API socket alongside the system one.
        system-manager manages system units, so this is accepted and nothing
        is emitted for it. Anything reaching podman over that socket, such as
        `podman --remote` or a `DOCKER_HOST` pointing at it, needs the socket
        creating by other means.
      '';
    };

    networking = {
      # Podman passes these to its service environment.
      proxy.envVars = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {};
        internal = true;
      };

      # Selects netavark's firewall driver. The host owns the ruleset, so this
      # records which driver netavark should write for, and nothing else.
      nftables.enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Whether the host firewall uses nftables. Netavark is configured to
          match, through `firewall_driver` in containers.conf.
        '';
      };

      firewall.backend = lib.mkOption {
        type = lib.types.enum ["iptables" "nftables" "firewalld"];
        default = "nftables";
        description = ''
          Firewall backend the host uses, which podman consults when choosing
          how to configure container networking.
        '';
      };
    };
  };

  config = lib.mkIf config.virtualisation.podman.enable {
    # system-manager declares `boot` to absorb kernel settings, without a
    # value. Podman reads `boot.supportedFilesystems` to find the ZFS tools.
    boot = lib.mkDefault {};
  };
}
