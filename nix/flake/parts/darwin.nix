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
          {pkgs, ...}:
            inputs.nix-darwin.lib.darwinSystem {
              inherit system pkgs;
              modules = [
                ../../os/darwin
                inputs.home-manager.darwinModules.home-manager
                # Embed home-manager in the darwin config so `darwin-rebuild switch`
                # handles both system and user config in one go.
                {
                  home-manager = {
                    useGlobalPkgs = true;
                    useUserPackages = true;
                    users.${username}.imports = helpers.mkHomeModules {
                      inherit
                        hostConfig
                        username
                        ;
                      inherit (config.flake) homeManagerModules;
                    };
                    extraSpecialArgs = helpers.mkHomeSpecialArgs {
                      inherit
                        hostConfig
                        hostname
                        system
                        inputs
                        username
                        ;
                    };
                  };
                }
              ];
              specialArgs = {
                inherit
                  inputs
                  hostname
                  hostConfig
                  username
                  ;
              };
            }
        )
    )
    darwinHosts;
}
