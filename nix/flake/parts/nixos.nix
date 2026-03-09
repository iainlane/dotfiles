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
      stable = pkgs-stable;
      unstable = pkgs;
      nixpkgs = inputs.nixpkgs-stable;
      home-manager = inputs.home-manager-stable;
      catppuccin = inputs.catppuccin-stable;
    }
    else {
      primary = pkgs;
      secondary = pkgs-stable;
      stable = pkgs-stable;
      unstable = pkgs;
      nixpkgs = inputs.nixpkgs;
      home-manager = inputs.home-manager;
      catppuccin = inputs.catppuccin;
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
                inputs = inputs // {
                  catppuccin = channel.catppuccin;
                };
                pkgs-stable = channel.stable;
                pkgs-unstable = channel.unstable;
              };
            };
          in
            channel.nixpkgs.lib.nixosSystem {
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
                  channel.home-manager.nixosModules.home-manager
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
                pkgs-stable = channel.stable;
                pkgs-unstable = channel.unstable;
              };
            }
        )
    )
    nixosHosts;
}
