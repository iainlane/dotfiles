let
  halls = import ../lib/halls.nix;
in {
  hostname = "melton.local";
  os = "darwin";
  arch = "aarch64";
  motd = halls.melton;
  profiles = [
    "base"
    "development"
    "desktop"
    "builder"
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
