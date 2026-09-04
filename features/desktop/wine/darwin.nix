{
  homebrew = {
    casks = [
      "gstreamer-runtime"
      "wine-stable"
    ];

    # Keep Wine's cask dependency in the Brewfile so cleanup preserves it,
    # but leave its installation and upgrades to Wine.
    onActivation.extraEnv.HOMEBREW_BUNDLE_CASK_SKIP = "gstreamer-runtime";
  };
}
