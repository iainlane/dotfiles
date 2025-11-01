{
  inputs,
  config,
  context,
  withSystem,
  ...
}:
# Produce nix-darwin system configurations for every macOS host.
let
  inherit
    (context)
    lib
    helpers
    darwinHosts
    username
    mkPkgs
    ;
in {
  flake.darwinConfigurations =
    lib.mapAttrs (
      hostname: hostConfig: let
        system = helpers.mkSystem hostConfig;
      in
        withSystem system (
          _: let
            pkgs = mkPkgs system;
          in
            inputs.nix-darwin.lib.darwinSystem {
              inherit system pkgs;
              modules = [
                ../../os/darwin
                inputs.home-manager.darwinModules.home-manager
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
