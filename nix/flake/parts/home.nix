{
  inputs,
  config,
  context,
  withSystem,
  ...
}:
# Build the Home Manager configurations for standalone management using
# `home-manager`. Shared helpers are used so that `deploy-rs` and
# `system-manager` stay in sync with this.
let
  inherit
    (context)
    lib
    helpers
    hosts
    username
    ;
in {
  flake.homeConfigurations =
    lib.mapAttrs' (
      hostname: hostConfig: let
        system = helpers.mkSystem hostConfig;
        configName = "${username}@${hostname}";
      in
        lib.nameValuePair configName (
          withSystem system (
            {pkgs, ...}:
              inputs.home-manager.lib.homeManagerConfiguration {
                inherit pkgs;
                modules = helpers.mkHomeModules {
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
              }
          )
        )
    )
    hosts;
}
