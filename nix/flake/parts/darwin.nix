{
  inputs,
  config,
  context,
  withSystem,
  ...
}:
# Produce nix-darwin system configurations for macOS hosts.
let
  inherit
    (context)
    lib
    helpers
    darwinHosts
    username
    ;
in {
  flake.darwinConfigurations =
    lib.mapAttrs (
      hostname: hostConfig: let
        system = helpers.mkSystem hostConfig;
      in
        withSystem system (
          args: let
            inherit (args.config._module.args) pkgs pkgs-stable;
            homeConfig = helpers.mkHomeConfiguration {
              inherit
                hostConfig
                hostname
                system
                username
                ;
              inherit (config.flake) profiles;
              extraSpecialArgs = {
                pkgs-unstable = pkgs;
              };
            };
          in
            inputs.nix-darwin.lib.darwinSystem {
              inherit system pkgs;
              modules =
                [
                  ../../os/darwin
                  config.flake.nix.substitutersModule
                ]
                ++ helpers.mkSystemModules {
                  inherit hostConfig;
                  inherit (config.flake) profiles;
                }
                ++ [
                  inputs.home-manager.darwinModules.home-manager
                  # Embed home-manager in the darwin config so `darwin-rebuild switch`
                  # handles both system and user config in one go.
                  {
                    home-manager = {
                      useGlobalPkgs = true;
                      useUserPackages = true;
                      users.${username}.imports = homeConfig.modules;
                      inherit (homeConfig) extraSpecialArgs;
                    };
                  }
                ];
              specialArgs = {
                inherit
                  inputs
                  hostname
                  hostConfig
                  pkgs-stable
                  username
                  ;
              };
            }
        )
    )
    darwinHosts;
}
