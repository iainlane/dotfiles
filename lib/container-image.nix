# Container images built from a Nix closure.
#
# Packages come from nixpkgs and the image is assembled here, so a container
# is pinned by the same lock as everything else and needs no registry. Images
# for software nixpkgs does not carry, such as the ADS-B feeders, are pulled
# from their publisher instead.
#
# Takes `pkgs` rather than being a module, because its callers are in
# different evaluations: Home Manager for the rootless containers, and
# system-manager for the rootful ones.
{pkgs}: {
  # With `tag` unset, `buildLayeredImage` derives `imageTag` from the store
  # hash of the image configuration. The service unit names that tag, so a
  # changed image changes the unit and the container restarts on deploy.
  mkNixImage = name: contents:
    pkgs.dockerTools.buildLayeredImage {
      inherit name contents;
      # A layered image carries only its closure, and several programs expect
      # somewhere to write: signal-cli extracts a native library at startup,
      # Caddy writes while renewing certificates.
      extraCommands = "mkdir -m 1777 tmp";
    };
}
