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
    nixosHosts
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
        sshUser = username;
        profiles.system = {
          user = "root";
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
        sshUser = username;
        # `sudo-rs` on some Linux hosts does not preserve a PATH that includes
        # Nix binaries; run as a login shell so root picks up nix-daemon profile.
        sudo = "sudo -S -i -u";
        profiles.system = {
          user = "root";
          path =
            deployLib.activate.custom config.flake.systemConfigs.${hostname}.config.build.toplevel
            "$PROFILE/bin/activate";
        };
      }
    )
    linuxHosts;

  # Build NixOS deploy nodes
  nixosNodes =
    lib.mapAttrs (
      hostname: hostConfig: let
        system = helpers.mkSystem hostConfig;
        deployLib = inputs.deploy-rs.lib.${system};
      in {
        inherit (hostConfig) hostname;
        sshUser = username;
        profiles.system = {
          user = "root";
          path =
            deployLib.activate.nixos
            config.flake.nixosConfigurations.${hostname};
        };
      }
    )
    nixosHosts;

  # Merge all nodes from all OSes
  allNodes = darwinNodes // linuxNodes // nixosNodes;

  # Add home-manager profile to each node (skip NixOS hosts which have it embedded)
  nodes =
    lib.mapAttrs (
      hostname: node: let
        hostConfig = hosts.${hostname};
        system = helpers.mkSystem hostConfig;
        deployLib = inputs.deploy-rs.lib.${system};
        homeConfigName = "${username}@${hostname}";
      in
        if hostConfig.os == "nixos"
        then node
        else
          node
          // {
            profiles =
              node.profiles
              // {
                ${username} = {
                  user = username;
                  path =
                    deployLib.activate.home-manager
                    config.flake.homeConfigurations.${homeConfigName};
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
