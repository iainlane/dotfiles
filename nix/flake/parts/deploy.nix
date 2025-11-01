{
  inputs,
  config,
  context,
  ...
}: let
  inherit
    (context)
    lib
    helpers
    hosts
    darwinHosts
    linuxHosts
    username
    ;

  # Build darwin deploy nodes
  darwinNodes =
    lib.mapAttrs (
      hostname: hostConfig: let
        system = helpers.mkSystem hostConfig;
        deployLib = inputs.deploy-rs.lib.${system};
      in {
        inherit (hostConfig) hostname;
        profiles.system = {
          path = deployLib.activate.darwin config.flake.darwinConfigurations.${hostname};
        };
      }
    )
    darwinHosts;

  # Build linux deploy nodes
  linuxNodes =
    lib.mapAttrs (
      hostname: hostConfig: let
        system = helpers.mkSystem hostConfig;
        deployLib = inputs.deploy-rs.lib.${system};
      in {
        inherit (hostConfig) hostname;
        profiles.system = {
          path =
            deployLib.activate.custom config.flake.systemConfigs.${hostname}.config.build.toplevel
            "$PROFILE/bin/activate";
        };
      }
    )
    linuxHosts;

  # Merge all nodes from both OSes
  allNodes = darwinNodes // linuxNodes;

  # Add home-manager profile to each node
  nodes =
    lib.mapAttrs (
      hostname: node: let
        hostConfig = hosts.${hostname};
        system = helpers.mkSystem hostConfig;
        deployLib = inputs.deploy-rs.lib.${system};
        homeConfigName = "${username}@${hostname}";
      in
        node
        // {
          profiles =
            node.profiles
            // {
              ${username} = {
                user = username;
                path = deployLib.activate.home-manager config.flake.homeConfigurations.${homeConfigName};
              };
            };
        }
    )
    allNodes;

  deploy = {inherit nodes;};

  # Run `deploy-rs` checks only for hosts matching the current system, avoiding
  # cross-compilation during `nix flake check`.
  checks = let
    targetSystems = lib.unique (map helpers.mkSystem (builtins.attrValues hosts));
    # Only check systems we can build for natively. In pure eval mode
    # (builtins.currentSystem unavailable), skip checks entirely.
    supportedSystems =
      if builtins ? currentSystem
      then lib.filter (system: system == builtins.currentSystem) targetSystems
      else [];
    mkChecks = system: {
      ${system} = inputs.deploy-rs.lib.${system}.deployChecks deploy;
    };
  in
    lib.foldl' (acc: system: acc // (mkChecks system)) {} supportedSystems;
in {
  flake = {
    inherit deploy;
  };

  # Add deploy-rs checks to the per-system checks
  perSystem = {system, ...}: {
    checks = checks.${system} or {};
  };
}
