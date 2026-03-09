{
  inputs,
  config,
  context,
  withSystem,
  ...
}: let
  inherit
    (context)
    lib
    helpers
    nixosHosts
    username
    ;

  channelPkgs = {
    hostConfig,
    pkgs,
    pkgs-stable,
  }:
    if (hostConfig.channel or "unstable") == "stable"
    then {
      primary = pkgs-stable;
      secondary = pkgs;
    }
    else {
      primary = pkgs;
      secondary = pkgs-stable;
    };
in {
  flake.nixosConfigurations =
    lib.mapAttrs (
      hostname: hostConfig: let
        system = helpers.mkSystem hostConfig;
      in
        withSystem system (
          {
            pkgs,
            pkgs-stable,
            ...
          }: let
            channel = channelPkgs {
              inherit hostConfig pkgs pkgs-stable;
            };
            homeConfig = helpers.mkHomeConfiguration {
              inherit
                hostConfig
                hostname
                system
                username
                ;
              inherit (config.flake) profiles;
              extraSpecialArgs = {
                inherit (channel) secondary;
                pkgs-stable =
                  if (hostConfig.channel or "unstable") == "stable"
                  then channel.primary
                  else channel.secondary;
                pkgs-unstable =
                  if (hostConfig.channel or "unstable") == "stable"
                  then channel.secondary
                  else channel.primary;
              };
            };
          in
            channel.primary.lib.nixosSystem {
              inherit system;
              pkgs = channel.primary;
              modules =
                [
                  ../../hosts/${hostname}/hardware.nix
                  ../../hosts/${hostname}/disks.nix
                  ../../os/nixos
                  inputs.disko.nixosModules.disko
                  inputs.sops-nix.nixosModules.sops
                  inputs.lanzaboote.nixosModules.lanzaboote
                  config.flake.nix.substitutersModule
                ]
                ++ helpers.mkNixosModules {
                  inherit hostConfig;
                  inherit (config.flake) profiles;
                }
                ++ [
                  inputs.home-manager.nixosModules.home-manager
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
                  username
                  ;
                pkgs-stable =
                  if (hostConfig.channel or "unstable") == "stable"
                  then channel.primary
                  else channel.secondary;
                pkgs-unstable =
                  if (hostConfig.channel or "unstable") == "stable"
                  then channel.secondary
                  else channel.primary;
              };
            }
        )
    )
    nixosHosts;
}
