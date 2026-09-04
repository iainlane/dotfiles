# The network configuration of a host whose links systemd-networkd manages.
#
# NixOS's networkd module supplies the option types and renders the unit files.
# This feature writes them to /etc/systemd/network and reloads networkd when
# they change. It does not install systemd-networkd itself: the host
# distribution ships it, and this only describes the links.
#
# The host's own address on the LAN is derived from that configuration, so a
# service publishing a container port to it does not repeat the address.
{
  flake.features.network.systemManager.imports = [
    ./options.nix
    ./system-manager.nix
  ];
}
