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
      profilesOrder = ["system" username];
      profiles = {
        system = result.systemProfile deployLib result.configuration;
        ${username} = {
          user = username;
          path = deployLib.activate.home-manager result.homeConfiguration;
        };
      };
    }
    // result.deployment)
  hosts;
in {
  deploy = {inherit nodes;};
  checks = import ./checks.nix {inherit lib hosts nodes deployLibFor;};
}
