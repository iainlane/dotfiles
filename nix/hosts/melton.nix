{
  hostname = "melton.local";
  os = "darwin";
  arch = "aarch64";
  profiles = [
    "base"
    "development"
    "desktop"
    "home"
  ];

  homeModule = _: {
    targets.darwin.defaults = {
      NSGlobalDomain = {
        AppleShowAllExtensions = true;
        InitialKeyRepeat = 15;
        KeyRepeat = 2;
      };
    };
  };
}
