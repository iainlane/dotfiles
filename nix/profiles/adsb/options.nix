{lib, ...}: {
  options.services.adsb = {
    secretsFile = lib.mkOption {
      type = lib.types.str;
      description = "Filename within the secrets input containing adsb secrets.";
    };

    ageSshKeyPaths = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "SSH private key paths used by sops age decryption.";
      example = [".ssh/age-sops"];
    };
  };
}
