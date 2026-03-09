{
  hostname = "melton.local";
  os = "darwin";
  arch = "aarch64";
  profiles = [
    "base"
    "development"
    "desktop"
    "builder"
    "home"
  ];

  # Resources for the local Linux builder VM on this host.
  linuxBuilder = {
    cores = 6;
    memoryMiB = 8192;
    systems = [
      "aarch64-linux"
      "x86_64-linux"
    ];
  };

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
