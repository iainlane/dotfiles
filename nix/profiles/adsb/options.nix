{lib, ...}: {
  options.services.adsb = {
    secretsFile = lib.mkOption {
      type = lib.types.str;
      description = "Filename within the secrets input containing adsb secrets.";
    };
  };
}
