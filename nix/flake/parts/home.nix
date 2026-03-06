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
            args: let
              inherit (args.config._module.args) pkgs;
              homeConfig = helpers.mkHomeConfiguration {
                inherit
                  hostConfig
                  hostname
                  system
                  username
                  ;
                inherit (config.flake) profiles;
              };
            in
              inputs.home-manager.lib.homeManagerConfiguration {
                inherit pkgs;
                modules = homeConfig.modules;
                extraSpecialArgs = homeConfig.extraSpecialArgs;
              }
          )
        )
    )
    hosts;
}
