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
    {
      adsb = {
        secretsFile = "adsb.yaml";
      };
    }
  ];
}
