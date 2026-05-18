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
    {"builder" = {admin = true;};}

    "home"
  ];

  homeModule = _: {
    dotfiles.git.signing.key = "E352D5C51C5041D4";

    targets.darwin.defaults = {
      NSGlobalDomain = {
        AppleShowAllExtensions = true;
        InitialKeyRepeat = 15;
        KeyRepeat = 2;
      };
    };
  };
}
