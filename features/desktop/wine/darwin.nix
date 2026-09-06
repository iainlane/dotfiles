{
  homebrew = {
    casks = [
      "gstreamer-runtime"
      "wine-stable"
    ];

    # Keep Wine's cask dependency in the Brewfile so cleanup preserves it,
    # but leave installing and upgrading it to the wine-stable cask.
    onActivation.extraEnv.HOMEBREW_BUNDLE_CASK_SKIP = "gstreamer-runtime";
  };
}
