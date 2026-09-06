{
  hostConfig,
  lib,
  ...
}: let
  exposeOption = subject:
    lib.mkOption {
      type = lib.types.nullOr (lib.types.submodule (import ../../lib/exposed-service.nix));
      default = null;
      example = lib.literalExpression ''
        {
          domain = "adsb.example.org";
          auth = true;
        }
      '';
      description = ''
        Serve ${subject} through the host's reverse proxy. With this null, the
        container stays on the feeder network, reachable only by the other
        containers on it.
      '';
    };
in {
  options.dotfiles.adsb = {
    secretsFile = lib.mkOption {
      type = lib.types.str;
      default = "${hostConfig.name}/host-adsb.yaml";
      example = "ancaster/host-adsb.yaml";
      description = ''
        Path, relative to the `secrets` flake input, of the sops file
        containing `latitude`, `longitude`, `altitude`, `piaware_feeder_id`,
        `fr24_sharing_key` and `planewatch_api_key`. The feeders run as system
        services, so this file is encrypted to the host key.

        The default puts the file in the host's own directory. A path outside
        one is allowed too, and ancaster uses `adsb.yaml` at the root of the
        secrets repository: the values describe where the aerial is and which
        aggregator accounts the feeds belong to, so moving the receiver to
        another machine reuses the same file. Every host pointed at a shared
        file has to be among its sops recipients.
      '';
    };

    expose = exposeOption "the tar1090 map";

    piaware.expose = exposeOption "piaware's own status page";

    fr24.expose = exposeOption "the FlightRadar24 feeder's own status page";
  };
}
