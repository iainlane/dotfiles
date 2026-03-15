let
  halls = import ../lib/halls.nix;
in {
  hostname = "sherwood";
  os = "linux";
  arch = "x86_64";
  motd = halls.sherwood;
  profiles = [
    "base"
    "development"
    "containers"
    "builder"
    "desktop"
    "home"
  ];

  homeModule = _: {
    dotfiles.git.signing.key = "E352D5C51C5041D4";
  };
}
