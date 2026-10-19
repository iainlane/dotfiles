{
  homebrew = {
    enable = true;

    enableZshIntegration = true;

    onActivation = {
      autoUpdate = true;
      cleanup = "uninstall";
      upgrade = true;
    };
  };
}
