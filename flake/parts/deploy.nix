{
  inputs,
  config,
  lib,
  hostResults,
  ...
}: let
  inherit (config.flake) username;
  inherit (config.flake) hosts;
  deployLibFor = system: (import ../../lib/deploy-rs {inherit inputs system;}).lib;

  nodes =
    lib.mapAttrs (
      hostname: hostConfig: let
        deployLib = deployLibFor hostConfig.system;
        systemProfile = hostResults.${hostname}.systemProfile deployLib hostResults.${hostname}.configuration;
      in
        {
          inherit (hostConfig) hostname;
          sshUser = username;
          profilesOrder = ["system" username];
          # Every host gets its own home-manager profile, so
          # `deploy .#<host>.<username>` updates the user configuration
          # without touching the system. NixOS and darwin embed Home Manager
          # as well, and this profile is how the home half is deployed on its
          # own.
          profiles = {
            system = systemProfile;
            ${username} = {
              user = username;
              path =
                deployLib.activate.home-manager
                config.flake.homeConfigurations."${username}@${hostname}";
            };
          };
        }
        // hostResults.${hostname}.deployment
    )
    hosts;

  deploy = {inherit nodes;};

  # `deploy-schema` serialises the node set into a JSON file and validates it.
  # Each profile path is a store path with string context, so the JSON file
  # would depend on every host's closure and validation would build them all.
  # Discard the context: the schema checks the paths as plain strings.
  schemaNodes =
    lib.mapAttrs (
      _: node:
        node
        // {
          profiles =
            lib.mapAttrs (
              _: profile:
                profile
                // {
                  path = builtins.unsafeDiscardStringContext "${profile.path}";
                }
            )
            node.profiles;
        }
    )
    nodes;

  mkChecks = system: let
    inherit (deployLibFor system) deployChecks;
    # `deploy-activate` builds each profile to look for its activation script,
    # so it gets only the hosts built for this system.
    nativeNodes =
      lib.filterAttrs (hostname: _: hosts.${hostname}.system == system) nodes;
  in {
    deploy-schema = lib.lazyDerivation {
      derivation = (deployChecks {nodes = schemaNodes;}).deploy-schema;
      passthru = {
        ci.runOnce = true;
        requiredSystemFeatures = [];
      };
    };
    deploy-activate = lib.lazyDerivation {
      derivation = (deployChecks {nodes = nativeNodes;}).deploy-activate;
      passthru.requiredSystemFeatures = [];
    };
  };
in {
  flake = {
    inherit deploy;
  };

  perSystem = {system, ...}: {
    checks = mkChecks system;
  };
}
