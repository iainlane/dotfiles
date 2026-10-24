{
  inputs,
  lib,
  hosts,
  username,
  hostResults,
  deployLibFor ? system: (import ../../lib/deploy-rs {inherit inputs system;}).lib,
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
  checks = import ./checks.nix {inherit inputs lib hosts nodes deployLibFor;};
}
