# Keep the healthcheck backports for the stable channel's Podman 5.8.
_: _: prev: {
  podman =
    if prev.lib.versionAtLeast prev.podman.version "6.0.0"
    then prev.podman
    else
      prev.podman.overrideAttrs (old: {
        patches =
          (old.patches or [])
          ++ [
            ./podman/0001-podman-healthcheck-run-add-ignore-result-flag.patch
            ./podman/0002-healthcheck_linux-avoid-failing-transient-units.patch
          ];
      });
}
