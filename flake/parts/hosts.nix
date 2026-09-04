{
  inputs,
  lib,
  config,
  withSystem,
  ...
}: let
  helpers = import ../../lib/helpers.nix {inherit inputs;};
  operatingSystems = ["nixos" "generic-linux" "darwin"];
  inherit (config.dotfiles) username;
  outerConfig = config;
  inherit (config._module.args.context) overlays nixpkgsConfig;

  osArgs = {
    inherit
      inputs
      lib
      withSystem
      helpers
      username
      overlays
      nixpkgsConfig
      ;
    config = outerConfig;
  };

  osModules = {
    nixos = import ../../os/nixos osArgs;
    "generic-linux" = import ../../os/generic-linux osArgs;
    darwin = import ../../os/darwin osArgs;
  };

  inherit (outerConfig.flake) hosts;

  hostAdapters =
    lib.mapAttrs (
      _: hostConfig:
        osModules.${hostConfig.os} hostConfig
    )
    hosts;

  homeDefinitions =
    lib.mapAttrs (
      hostname: hostConfig: let
        adapter = hostAdapters.${hostname};
      in
        helpers.mkHomeDefinition {
          inherit
            hostConfig
            username
            ;
          inherit (hostConfig) system;
          extraModules = adapter.extraHomeModules or [];
          extraSpecialArgs = adapter.homeSpecialArgs;
        }
    )
    hosts;

  hostResults =
    lib.mapAttrs (
      hostname: adapter: {
        inherit (adapter) homeBaseDir systemSuffix;
        systemConfig = adapter.mkSystemConfig homeDefinitions.${hostname};
      }
    )
    hostAdapters;

  # The standalone output must build from the same channel as the host's
  # system configuration, so that applying it directly produces the packages
  # the system build would.
  mkStandaloneHome = hostname: hostConfig: let
    onStable = hostConfig.channel == "stable";

    home-manager =
      if onStable
      then inputs.home-manager-stable
      else inputs.home-manager;
  in
    withSystem hostConfig.system (
      args: let
        inherit (args.config._module.args) pkgs pkgs-stable;
      in
        home-manager.lib.homeManagerConfiguration {
          pkgs =
            if onStable
            then pkgs-stable
            else pkgs;
          inherit (homeDefinitions.${hostname}) modules extraSpecialArgs;
        }
    );

  hostModule = {
    name,
    config,
    ...
  }: let
    result = hostResults.${name};
  in {
    options = {
      name = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        default = name;
        description = "The host's key in `flake.hosts`. The secrets repository, the AgentsView roles and everything else that needs a short name for the machine use it.";
      };
      os = lib.mkOption {
        type = lib.types.enum outerConfig.dotfiles.operatingSystems;
      };
      arch = lib.mkOption {
        type = lib.types.enum ["x86_64" "aarch64"];
      };
      hostname = lib.mkOption {
        type = lib.types.str;
        default = name;
      };
      features = lib.mkOption {
        type = lib.types.listOf helpers.featureType;
        default = [];
        description = "Entries of `flake.features`. Each one brings the features it includes.";
      };
      channel = lib.mkOption {
        type = lib.types.enum ["stable" "unstable"];
        default = "unstable";
      };
      stateVersion = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
      };
      timezone = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Timezone in TZ format, e.g. 'Europe/London'. Set to null to skip timezone configuration and let `systemd-timedated` manage.";
      };
      locale = lib.mkOption {
        type = lib.types.str;
        default = "en_GB.UTF-8";
      };
      motd = lib.mkOption {
        type = lib.types.str;
      };
      flakePath = lib.mkOption {
        type = lib.types.str;
        default = "${config.homeDirectory}/dev/random/dotfiles";
        description = "Where this flake is checked out on the host. `nh` builds from that checkout, and the Neovim lock file is a symlink into it, so plugin updates are written to the working tree.";
      };
      homeModule = lib.mkOption {
        type = lib.types.nullOr lib.types.deferredModule;
        default = null;
        description = "Home Manager module for this host only.";
      };
      systemModule = lib.mkOption {
        type = lib.types.nullOr lib.types.deferredModule;
        default = null;
        description = "Module for this host only, for whichever of NixOS, nix-darwin or system-manager builds it.";
      };

      # Computed
      featureNames = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        readOnly = true;
        default = helpers.featureNames {inherit (config) features os;};
        description = "The name of every feature the host has, including the ones its features include.";
      };
      homeDirectory = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        default = "${result.homeBaseDir}/${username}";
      };
      system = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        default = "${config.arch}-${result.systemSuffix}";
      };
    };
  };
in {
  options = {
    dotfiles.operatingSystems = lib.mkOption {
      type = with lib.types; listOf str;
      default = operatingSystems;
      readOnly = true;
    };

    flake.hosts = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule hostModule);
      default = {};
      description = "One entry per machine. The files under `hosts/` define them.";
    };
  };

  config.flake = {
    # Route system configs to the right flake output per OS
    nixosConfigurations =
      lib.mapAttrs (_: r: r.systemConfig)
      (lib.filterAttrs (n: _: hosts.${n}.os == "nixos") hostResults);

    systemConfigs =
      lib.mapAttrs (_: r: r.systemConfig)
      (lib.filterAttrs (n: _: hosts.${n}.os == "generic-linux") hostResults);

    darwinConfigurations =
      lib.mapAttrs (_: r: r.systemConfig)
      (lib.filterAttrs (n: _: hosts.${n}.os == "darwin") hostResults);

    # Standalone home-manager configurations for all hosts
    homeConfigurations =
      lib.mapAttrs' (
        hostname: hostConfig:
          lib.nameValuePair "${username}@${hostname}" (
            mkStandaloneHome hostname hostConfig
          )
      )
      hosts;
  };
}
