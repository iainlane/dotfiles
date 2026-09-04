{lib, ...}: {
  options.services.adsb = {
    secretsFile = lib.mkOption {
      type = lib.types.str;
      description = "Filename within the secrets input containing adsb secrets.";
    };

    expose = lib.mkOption {
      default = null;
      example = lib.literalExpression ''
        {
          domain = "adsb.example.org";
          auth = true;
        }
      '';
      description = ''
        Serve the tar1090 map through the host's reverse proxy. Leave null and
        the feeder keeps to its own network, where only the containers sharing
        it can reach the map.
      '';
      type = lib.types.nullOr (lib.types.submodule ../../lib/exposed-service.nix);
    };
  };
}
