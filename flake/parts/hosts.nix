{
  inputs,
  lib,
  config,
  withSystem,
  overlays,
  nixpkgsConfig,
  featureResolver,
  ...
}: let
  home = import ../../lib/home.nix {inherit inputs lib featureResolver;};
  channels = import ../../lib/channels.nix {inherit inputs;};
  operatingSystems = import ../../lib/operating-systems.nix;
  inherit (config.flake) username;
  outerConfig = config;

  osArgs = {
    inherit
      inputs
      lib
      withSystem
      username
      overlays
      nixpkgsConfig
      featureResolver
      ;
    config = outerConfig;
  };

  osModules =
    lib.genAttrs (lib.attrNames operatingSystems)
    (os: import (../../os + "/${os}") osArgs);

  inherit (outerConfig.flake) hosts;

  hostAdapters =
    lib.mapAttrs (
      _: hostConfig:
        osModules.${hostConfig.os} hostConfig
    )
    hosts;

  homeDefinitions =
    lib.mapAttrs (
      hostname: hostConfig:
        home.mkHomeDefinition {
          inherit
            hostConfig
            username
            ;
          inherit (hostAdapters.${hostname}) homeSpecialArgs;
        }
    )
    hosts;

  systemConfigurations =
    lib.mapAttrs (
      hostname: adapter:
        adapter.mkSystemConfig homeDefinitions.${hostname}
    )
    hostAdapters;

  # The standalone output must build from the same channel as the host's
  # system configuration, so that applying it directly produces the packages
  # the system build would.
  mkStandaloneHome = hostname: hostConfig:
    withSystem hostConfig.system (
      {
        pkgs,
        pkgs-stable,
        ...
      }: let
        channel = channels.channelFor {
          inherit (hostConfig) channel;
          inherit pkgs pkgs-stable;
        };
      in
        channel.home-manager.lib.homeManagerConfiguration {
          pkgs = channel.primary;
          inherit (homeDefinitions.${hostname}) modules extraSpecialArgs;
        }
    );

  hostModule = {
    name,
    config,
    ...
  }: {
    options = {
      name = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        default = name;
        description = "The host's key in `flake.hosts`. The secrets repository, the AgentsView roles and everything else that needs a short name for the machine use it.";
      };
      os = lib.mkOption {
        type = lib.types.enum outerConfig.flake.operatingSystems;
        description = "The operating system the machine runs. It decides which module system builds the host and which flake output the result appears under.";
      };
      arch = lib.mkOption {
        type = lib.types.enum ["x86_64" "aarch64"];
        description = "The machine's CPU architecture. With the OS it makes the host's Nix system string.";
      };
      hostname = lib.mkOption {
        type = lib.types.str;
        default = name;
        description = "The machine's network name. NixOS sets `networking.hostName` to it and the ADS-B feeder registers under it. A machine with a domain gives its fully qualified name here; `name` is the short name.";
      };
      features = lib.mkOption {
        type = lib.types.listOf featureResolver.featureType;
        default = [];
        description = "Entries of `flake.features`. Each one brings the features it includes.";
      };
      excludes = lib.mkOption {
        type = lib.types.listOf featureResolver.featureType;
        default = [];
        description = "Entries of `flake.features` this host drops. An excluded feature contributes no modules and its own includes are not followed. Listing a feature and excluding it, or excluding one this host's features never reach, is an error.";
      };
      channel = lib.mkOption {
        type = lib.types.enum ["stable" "unstable"];
        default = "unstable";
        description = ''
          Which of the two locked nixpkgs and Home Manager pairs this host
          builds from. It selects the package set the system configuration
          and both forms of the Home Manager configuration are built from,
          the nixpkgs the host's netboot installer is built from, and the
          MCP server set the AI features configure. On a `generic-linux`
          host it does not select the nixpkgs the system configuration is
          evaluated against: system-manager uses the nixpkgs its own flake
          input follows.
        '';
      };
      stateVersion = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "The value of `system.stateVersion`: the NixOS release whose defaults for stateful data the host keeps. Only the NixOS adapter reads it, so hosts on the other two operating systems leave it null.";
      };
      timezone = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Timezone in TZ format, e.g. 'Europe/London'. Only the NixOS adapter reads it. Set it to null to leave the timezone to `systemd-timedated`.";
      };
      locale = lib.mkOption {
        type = lib.types.str;
        default = "en_GB.UTF-8";
        description = "The default locale, as `i18n.defaultLocale`. Only the NixOS adapter reads it.";
      };
      motd = lib.mkOption {
        type = lib.types.str;
        description = "The message of the day, which the base feature writes to `~/.motd`. The shell does not display it at login.";
      };
      flakePath = lib.mkOption {
        type = lib.types.str;
        default = "${config.homeDirectory}/dev/random/dotfiles";
        description = "Where this flake is checked out on the host. `nh` builds from that checkout, and the Neovim lock file is a symlink into it, so plugin updates are written to the working tree.";
      };
      homeModule = lib.mkOption {
        type = lib.types.deferredModule;
        default = {};
        description = "Home Manager module for this host only. Several files may define it, and the module system merges them.";
      };
      systemModule = lib.mkOption {
        type = lib.types.deferredModule;
        default = {};
        description = "Module for this host only, for whichever of NixOS, nix-darwin or system-manager builds it. Several files may define it, and the module system merges them.";
      };

      # Computed
      featureNames = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        readOnly = true;
        default = featureResolver.featureNames {inherit (config) features os excludes;};
        description = "The name of every feature the host has, including the ones its features include.";
      };
      homeDirectory = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        default = "${operatingSystems.${config.os}.homeBaseDir}/${username}";
        description = "Where the user's home directory is on this host.";
      };
      system = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        default = "${config.arch}-${operatingSystems.${config.os}.systemSuffix}";
        description = "The Nix system string the host builds for.";
      };
    };
  };

  # Each operating system's hosts go to the flake output named in the OS table.
  systemOutputs =
    lib.mapAttrs' (
      os: entry:
        lib.nameValuePair entry.outputName (
          lib.filterAttrs (hostname: _: hosts.${hostname}.os == os) systemConfigurations
        )
    )
    operatingSystems;
in {
  options = {
    flake.operatingSystems = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = lib.attrNames operatingSystems;
      readOnly = true;
      description = "The operating systems a host record can name, from the table in `lib/operating-systems.nix`.";
    };

    flake.hosts = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule hostModule);
      default = {};
      description = "One entry per machine. The files under `hosts/` define them.";
    };
  };

  config.flake =
    systemOutputs
    // {
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
