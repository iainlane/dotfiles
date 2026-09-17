# Adapter for nixos/modules/virtualisation/podman and its containers module.
#
# Imports the upstream NixOS modules so `virtualisation.podman` and
# `virtualisation.containers` mean the same here as they do on NixOS: the
# podman package and socket, /etc/containers/policy.json, registries.conf,
# storage.conf and containers.conf.
#
# Defines the options that those modules reference but system-manager does not
# have. Each description says what happens to the value that it is given.
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
    dotfiles.containers.subnetPools = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = ''
        Podman's compiled-in `default_subnet_pools`, from which it allocates
        network addresses. The proxy and database use these ranges to permit
        connections from containers. The ranges must match the pools Podman
        actually uses; an address in a range does not by itself establish
        which host sent a connection.
      '';
    };

    systemd.user.sockets = lib.mkOption {
      type = lib.types.attrs;
      default = {};
      internal = true;
      description = ''
        podman defines a per-user API socket alongside the system one.
        system-manager manages system units only, so this option is accepted
        and nothing is generated from it. Anything reaching podman over that
        socket, such as `podman --remote` or a `DOCKER_HOST` pointing at it,
        has to have the socket created some other way.
      '';
    };

    networking = {
      # podman passes these to its service environment.
      proxy.envVars = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {};
        internal = true;
      };

      # Selects netavark's firewall driver. The host owns the ruleset, so
      # setting this changes only which driver netavark writes rules for.
      nftables.enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Whether the host firewall uses nftables. netavark is configured to
          match, through `firewall_driver` in containers.conf.
        '';
      };

      firewall.backend = lib.mkOption {
        type = lib.types.enum ["iptables" "nftables" "firewalld"];
        default =
          if config.networking.nftables.enable
          then "nftables"
          else "iptables";
        defaultText = lib.literalExpression ''
          if config.networking.nftables.enable then "nftables" else "iptables"
        '';
        description = ''
          Firewall backend the host uses, which podman consults when choosing
          how to configure container networking. It follows
          `networking.nftables.enable`, as it does on NixOS.
        '';
      };
    };
  };

  config = lib.mkMerge [
    {
      dotfiles.containers.subnetPools = [
        "10.89.0.0/16"
        "10.90.0.0/15"
        "10.92.0.0/14"
        "10.96.0.0/11"
        "10.128.0.0/9"
      ];
    }

    (lib.mkIf config.virtualisation.podman.enable {
      # system-manager declares `boot` to absorb kernel settings and gives it
      # no default. The podman module reads `boot.supportedFilesystems` to
      # decide whether to add the ZFS tools.
      boot = lib.mkDefault {};
    })
  ];
}
