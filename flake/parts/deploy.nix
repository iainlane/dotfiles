{
  inputs,
  config,
  lib,
  ...
}: let
  inherit (config.flake) username;
  inherit (config.flake) hosts;
  operatingSystems = import ../../lib/operating-systems.nix;

  nodes =
    lib.mapAttrs (
      hostname: hostConfig: let
        deployLib = inputs.deploy-rs.lib.${hostConfig.system};
        configuration =
          config.flake.${operatingSystems.${hostConfig.os}.outputName}.${hostname};
        systemProfile =
          {
            nixos = {
              user = "root";
              path = deployLib.activate.nixos configuration;
            };
            "generic-linux" = {
              user = "root";
              path =
                deployLib.activate.custom
                configuration.config.build.toplevel
                "$PROFILE/bin/activate";
            };
            darwin = {
              user = "root";
              path = deployLib.activate.darwin configuration;
            };
          }
          .${
            hostConfig.os
          };
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
        // lib.optionalAttrs (hostConfig.os == "generic-linux") {
          # `sudo-rs` on some Linux hosts does not preserve a PATH that
          # includes the Nix binaries; run as a login shell so root picks up
          # the nix-daemon profile.
          sudo = "sudo -S -i -u";
        }
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
    inherit (inputs.deploy-rs.lib.${system}) deployChecks;
    # `deploy-activate` builds each profile to look for its activation script,
    # so it gets the hosts this system builds and no others.
    nativeNodes =
      lib.filterAttrs (hostname: _: hosts.${hostname}.system == system) nodes;
  in {
    inherit (deployChecks {nodes = schemaNodes;}) deploy-schema;
    inherit (deployChecks {nodes = nativeNodes;}) deploy-activate;
  };
in {
  flake = {
    inherit deploy;
  };

  perSystem = {system, ...}: {
    checks = mkChecks system;
  };
}
