let
  halls = import ../lib/halls.nix;
in {
  hostname = "florence.local";
  os = "linux";
  arch = "x86_64";
  motd = halls.florence;
  profiles = [
    "base"
    "desktop"
    "development"
    "containers"
    "builder"
    "cloud"
  ];
}
