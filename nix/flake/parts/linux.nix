{
  inputs,
  config,
  context,
  withSystem,
  ...
}:
# Produce system-manager configurations for Linux hosts.
let
  inherit
    (context)
    lib
    helpers
    linuxHosts
    username
    overlays
    nixpkgsConfig
    ;
in {
  flake.systemConfigs =
    lib.mapAttrs (
      hostname: hostConfig: let
        system = helpers.mkSystem hostConfig;
      in
        withSystem system (
          _:
            inputs.system-manager.lib.makeSystemConfig {
              inherit overlays;
              modules =
                [
                  config.flake.os.linux.systemManagerModule
                  config.flake.nix.substitutersModule
                ]
                ++ helpers.mkSystemModules {
                  inherit hostConfig;
                  inherit (config.flake) profiles;
                };
              extraSpecialArgs = {
                inherit
                  inputs
                  hostname
                  hostConfig
                  username
                  nixpkgsConfig
                  ;
              };
            }
        )
    )
    linuxHosts;
}
