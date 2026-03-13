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
}
