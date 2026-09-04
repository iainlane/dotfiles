{
  homebrew = {
    enable = true;

    enableZshIntegration = true;

    onActivation = {
      cleanup = "uninstall";
      upgrade = true;
    };
  };
}
