# Home Manager assembly: gather the Home Manager modules and special args for a
# host in one place so the standalone `homeConfigurations` output and the
# embedded configurations stay in sync. `resolveFeatures` and
# `mkHomeSopsModule` (secrets) are injected so this module only owns the Home
# Manager wiring itself.
{
  inputs,
  resolveFeatures,
  mkHomeSopsModule,
}: rec {
  mkHomeModules = {
    hostConfig,
    username,
  }:
    resolveFeatures {
      class = "homeManager";
      inherit hostConfig;
    }
    ++ [
      hostConfig.homeModule
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
    system,
    inputs,
    extraArgs ? {},
  }:
    {
      inherit
        inputs
        system
        hostConfig
        ;
      inherit (hostConfig) flakePath;
    }
    // extraArgs;

  # The home-manager settings module shared by the NixOS and nix-darwin
  # embeddings.
  mkEmbeddedHomeManager = {
    username,
    homeDefinition,
  }: {
    home-manager = {
      useGlobalPkgs = true;
      useUserPackages = true;
      users.${username}.imports = homeDefinition.modules;
      inherit (homeDefinition) extraSpecialArgs;
    };
  };

  # Assemble the modules and special arguments used by both forms of a host's
  # Home Manager configuration.
  mkHomeDefinition = {
    hostConfig,
    system,
    username,
    extraModules ? [],
    extraSpecialArgs ? {},
  }: {
    modules =
      mkHomeModules {inherit hostConfig username;}
      ++ [
        inputs.sops-nix.homeManagerModules.sops
        (mkHomeSopsModule {inherit hostConfig;})
      ]
      ++ extraModules;
    extraSpecialArgs = mkHomeSpecialArgs {
      inherit
        hostConfig
        system
        ;
      inherit inputs;
      extraArgs = extraSpecialArgs;
    };
  };
}
