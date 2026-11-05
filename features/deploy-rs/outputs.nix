{
  lib,
  hosts,
  username,
  hostResults,
  deployLibFor,
}: let
  nodes = lib.mapAttrs (hostname: host: let
    deployLib = deployLibFor host.system;
    result = hostResults.${hostname};
  in
    {
      inherit (host) hostname;
      sshUser = username;
      profilesOrder = ["system"] ++ lib.optional (result.home ? standalone) username;
      profiles =
        {
          system = result.systemProfile deployLib result.configuration;
        }
        // lib.optionalAttrs (result.home ? standalone) {
          ${username} = {
            user = username;
            path = deployLib.activate.home-manager result.home.standalone;
          };
        };
    }
    // result.deployment)
  hosts;
in {
  deploy = {inherit nodes;};
  checks = import ./checks.nix {inherit lib hosts nodes deployLibFor;};
}
