# Home Manager assembly: gather the Home Manager modules and special args for a
# host in one place so the standalone `homeConfigurations` output and the
# embedded configurations stay in sync.
{
  inputs,
  lib,
  featureResolver,
}: let
  inherit (featureResolver) resolveFeatures;
  inherit (import ./sops.nix {inherit inputs lib;}) mkHomeSopsModule;
  inherit (import ./channels.nix {inherit inputs;}) channelFor;

  # The unstable home-manager modules grafted on by
  # features/ai/unstable-hm-modules.nix and features/desktop/voxtype are
  # written against unstable's `lib.hm`, which has helpers (such as
  # `generators.mkDAGOrderedJsonFormat`) that the stable channel's `lib.hm`
  # does not yet have. Build an extended lib whose `lib.hm` comes from
  # unstable and hand it to the home-manager modules on stable hosts through
  # the special args, so both the embedded and standalone configurations
  # receive it. Special args take precedence over the home-manager module's
  # own `lib`, so the extended lib replaces it without rebuilding the stable
  # source.
  unstableHmLib = pkgs-stable:
    pkgs-stable.lib.extend (
      self: super: let
        hmLib = import "${inputs.home-manager}/modules/lib" {lib = self;};
      in {
        hm = hmLib;
        maintainers = super.maintainers // hmLib.maintainers;
      }
    );
in rec {
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

  # The special arguments every Home Manager module receives, whether it is
  # evaluated in the standalone configuration or in the one embedded in a
  # system configuration. Each OS adapter builds this set for its host, so a
  # module written for one OS finds the same arguments on the others.
  #
  # `pkgs` and `pkgs-stable` are the package sets flake-parts instantiated for
  # the host's system.
  mkHomeSpecialArgs = {
    hostConfig,
    mcpByChannel,
    pkgs,
    pkgs-stable,
  }: let
    channel = channelFor {
      inherit (hostConfig) channel;
      inherit pkgs pkgs-stable;
    };
  in
    {
      inherit inputs hostConfig;
      inherit (hostConfig) system flakePath;
      mcp = mcpByChannel.${hostConfig.channel};
      pkgs-unstable = channel.unstable;
    }
    // lib.optionalAttrs (hostConfig.channel == "stable") {
      lib = unstableHmLib channel.stable;
    };

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
    username,
    homeSpecialArgs,
  }: {
    modules =
      mkHomeModules {inherit hostConfig username;}
      ++ [
        inputs.sops-nix.homeManagerModules.sops
        (mkHomeSopsModule {inherit hostConfig;})
      ];
    extraSpecialArgs = homeSpecialArgs;
  };
}
