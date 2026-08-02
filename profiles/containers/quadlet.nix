# Rootful Podman quadlets, declared through `virtualisation.quadlet`.
#
# quadlet-nix supplies the module and `./podman.nix` the podman options and the
# /etc/containers files it builds on. Both vendored pieces are noted in
# `./vendored`; what remains here is the quadlet generator, which quadlet-nix
# expects the host's own podman to provide and this host has none.
{
  config,
  lib,
  ...
}: {
  imports = [
    ./podman.nix
    ./vendored/quadlet-system-manager-module.nix
    ./vendored/system-manager-dropin-units.nix
  ];

  config = lib.mkIf config.virtualisation.podman.enable {
    # The quadlet generator comes from podman itself, which the podman module
    # puts in `systemd.packages`. Naming the same package here means the
    # command lines quadlet-nix writes into the units it generates run the
    # podman that generated them.
    virtualisation.quadlet.podmanPackage = config.virtualisation.podman.package;
  };
}
