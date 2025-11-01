# Darwin-specific base configuration
_: {
  flake.homeManagerModules.base-darwin = _: {
    targets.darwin = {
      # Copy app bundles to ~/Applications so Spotlight indexes them directly.
      copyApps.enable = true;
      # Disable the old symlink approach (default for stateVersion < 25.11).
      linkApps.enable = false;
    };
  };
}
