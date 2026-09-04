# Rootful podman quadlets, declared through `virtualisation.quadlet`.
#
# quadlet-nix supplies the module and `./podman.nix` the podman options and the
# /etc/containers files it builds on. Both vendored pieces are noted in
# `./vendored`. What this file adds is the podman package quadlet-nix generates
# against: it expects the host distribution to supply podman, and these hosts
# run the podman that Nix builds.
{
  config,
  lib,
  ...
}: let
  quadlet = import ../../lib/quadlet.nix {inherit lib;};
  unsafeAutoUsernsVolumes =
    quadlet.autoUsernsVolumesWithoutIdmap config.virtualisation.quadlet.containers;
in {
  imports = [
    ./podman.nix
    ./vendored/quadlet-system-manager-module.nix
    ./vendored/system-manager-dropin-units.nix
  ];

  config = lib.mkIf config.virtualisation.podman.enable {
    assertions = [
      {
        assertion = unsafeAutoUsernsVolumes == [];
        message = ''
          Containers using `userns=auto` must mount every named volume
          with `idmap`:
          ${lib.concatMapStringsSep "\n" (
              volume: "  ${volume.container}: ${volume.mount}"
            )
            unsafeAutoUsernsVolumes}
        '';
      }
    ];

    # The quadlet generator comes from podman itself, which the podman module
    # puts in `systemd.packages`. Naming the same package here means the
    # command lines quadlet-nix writes into the units it generates run the
    # podman that generated them.
    virtualisation.quadlet.podmanPackage = config.virtualisation.podman.package;
  };
}
