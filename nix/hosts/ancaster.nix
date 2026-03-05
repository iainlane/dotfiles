{
  hostname = "ancaster.home.orangesquash.org.uk";
  os = "linux";
  arch = "aarch64";
  profiles = [
    "base"
    {
      adsb = {
        secretsFile = "adsb.yaml";
        ageSshKeyPaths = [".ssh/age-sops"];
      };
    }
  ];
}
