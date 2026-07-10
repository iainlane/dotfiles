# Home Manager assembly: gather the Home Manager modules and special args for a
# host in one place so the standalone `homeConfigurations` output and the
# NixOS/nix-darwin embeddings stay in sync. `mkModules` (profile resolution)
# and `mkHomeSopsModule` (secrets) are injected so this module only owns the
# Home Manager wiring itself.
{
  inputs,
  lib,
  mkModules,
  mkHomeSopsModule,
}: rec {
  mkHomeModules = {
    hostConfig,
    username,
    profiles,
    modules,
  }:
    mkModules {
      moduleType = "homeManagerModule";
      inherit hostConfig profiles modules;
    }
    ++ lib.optional (hostConfig.homeModule or null != null) hostConfig.homeModule
    ++ [
      {
        home = {
          inherit username;
          inherit (hostConfig) homeDirectory;
        };
      }
    ];

  # Construct the specialArgs attrset passed to home-manager modules. Provides
  # access to flake inputs, host metadata, and the canonical flake path.
  mkHomeSpecialArgs = {
    hostConfig,
    hostname,
    system,
    inputs,
    extraArgs ? {},
  }: let
    defaultFlakePath = "${hostConfig.homeDirectory}/dev/random/dotfiles";
    flakePath =
      if (hostConfig.flakePath or null) != null
      then hostConfig.flakePath
      else defaultFlakePath;
  in
    {
      inherit
        hostname
        inputs
        system
        hostConfig
        flakePath
        ;
    }
    // extraArgs;

  # The home-manager settings module shared by the NixOS and nix-darwin
  # embeddings. `extraSpecialArgs` entries are merged over the ones carried by
  # `homeConfig` (the NixOS adapter uses this to hand stable hosts an unstable
  # `lib`).
  mkEmbeddedHomeManager = {
    username,
    homeConfig,
    extraSpecialArgs ? {},
  }: {
    home-manager = {
      useGlobalPkgs = true;
      useUserPackages = true;
      users.${username}.imports = homeConfig.modules;
      extraSpecialArgs = homeConfig.extraSpecialArgs // extraSpecialArgs;
    };
  };

  # Assemble home-manager modules and special args for a host in one place so
  # standalone home-manager and nix-darwin embedding stay in sync.
  mkHomeConfiguration = {
    hostConfig,
    hostname,
    system,
    username,
    profiles,
    modules,
    extraModules ? [],
    extraSpecialArgs ? {},
  }: {
    modules =
      mkHomeModules {
        inherit
          hostConfig
          username
          profiles
          modules
          ;
      }
      ++ [
        inputs.sops-nix.homeManagerModules.sops
        (mkHomeSopsModule {inherit hostConfig;})
      ]
      ++ extraModules;
    extraSpecialArgs = mkHomeSpecialArgs {
      inherit
        hostConfig
        hostname
        system
        ;
      inherit inputs;
      extraArgs = extraSpecialArgs;
    };
  };
}
