{
  inputs,
  config,
  lib,
  ...
}: let
  username = "laney";
  inherit (config.flake) hosts;

  nodes =
    lib.mapAttrs (
      hostname: hostConfig: let
        deployLib = inputs.deploy-rs.lib.${hostConfig.system};
        systemProfile =
          {
            nixos = {
              user = "root";
              path =
                deployLib.activate.nixos
                config.flake.nixosConfigurations.${hostname};
            };
            linux = {
              user = "root";
              path =
                deployLib.activate.custom
                config.flake.systemConfigs.${hostname}.config.build.toplevel
                "$PROFILE/bin/activate";
            };
            darwin = {
              user = "root";
              path =
                deployLib.activate.darwin
                config.flake.darwinConfigurations.${hostname};
            };
          }
          .${
            hostConfig.os
          };
      in
        {
          inherit (hostConfig) hostname;
          sshUser = username;
          # Every host gets its own home-manager profile so you can
          # `deploy .#<host>.laney` to update just your user config without
          # touching the system. NixOS and darwin embed HM too, but this
          # lets you iterate on dotfiles quickly.
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
        // lib.optionalAttrs (hostConfig.os == "linux") {
          # `sudo-rs` on some Linux hosts does not preserve a PATH that includes
          # Nix binaries; run as a login shell so root picks up nix-daemon profile.
          sudo = "sudo -S -i -u";
        }
    )
    hosts;

  deploy = {inherit nodes;};

  # Run `deploy-rs` checks only for hosts matching the current system, avoiding
  # cross-compilation during `nix flake check`.
  checks = let
    targetSystems = lib.unique (map (h: h.system) (builtins.attrValues hosts));
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
