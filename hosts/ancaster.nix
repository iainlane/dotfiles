let
  halls = import ../lib/halls.nix;
in {
  hostname = "ancaster";
  os = "linux";
  arch = "aarch64";
  motd = halls.ancaster;
  profiles = [
    "base"
    "containers"
    "hermes"
    "nixbuild-substituter"
    {
      adsb = {
        secretsFile = "adsb.yaml";
      };
    }
    "unifi"
  ];
}
