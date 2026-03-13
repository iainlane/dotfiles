let
  halls = import ../lib/halls.nix;
in {
  hostname = "cripps";
  os = "linux";
  arch = "x86_64";
  motd = halls.cripps;
  profiles = ["base"];
}
