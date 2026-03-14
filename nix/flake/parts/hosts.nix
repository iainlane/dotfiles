{
  inputs,
  lib,
  config,
  withSystem,
  ...
}: let
  helpers = import ../../lib/helpers.nix {inherit inputs;};
  username = "laney";
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
    linux = import ../../os/linux osArgs;
    darwin = import ../../os/darwin osArgs;
  };

  # Call each host's OS module. Laziness means homeBaseDir/systemSuffix are
  # available without forcing systemConfig evaluation.
  hostResults =
    lib.mapAttrs (
      hostname: hostConfig:
        osModules.${hostConfig.os} hostname hostConfig
    )
    outerConfig.flake.hosts;

  mkStandaloneHome = hostname: hostConfig: let
    result = hostResults.${hostname};
    extraModules = result.extraHomeModules or [];
  in
    withSystem hostConfig.system (
      args: let
        inherit (args.config._module.args) pkgs;
        homeConfig = helpers.mkHomeConfiguration {
          inherit
            hostConfig
            hostname
            username
            ;
          inherit (hostConfig) system;
          inherit (outerConfig.flake) profiles;
          inherit extraModules;
          extraSpecialArgs = result.homeSpecialArgs;
        };
      in
        inputs.home-manager.lib.homeManagerConfiguration {
          inherit pkgs;
          inherit (homeConfig) modules extraSpecialArgs;
        }
    );
in {
  options.flake.hosts = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule ({
      name,
      config,
      ...
    }: let
      result = hostResults.${name};
    in {
      options = {
        os = lib.mkOption {
          type = lib.types.enum ["nixos" "linux" "darwin"];
        };
        arch = lib.mkOption {
          type = lib.types.enum ["x86_64" "aarch64"];
        };
        hostname = lib.mkOption {
          type = lib.types.str;
          default = name;
        };
        profiles = lib.mkOption {
          type = with lib.types; listOf unspecified;
          default = [];
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
          type = lib.types.str;
          default = "Europe/London";
        };
        locale = lib.mkOption {
          type = lib.types.str;
          default = "en_GB.UTF-8";
        };
        motd = lib.mkOption {
          type = lib.types.str;
        };
        flakePath = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
        };
        homeModule = lib.mkOption {
          type = lib.types.nullOr lib.types.unspecified;
          default = null;
        };
        systemModule = lib.mkOption {
          type = lib.types.nullOr lib.types.unspecified;
          default = null;
        };
        nixosModule = lib.mkOption {
          type = lib.types.nullOr lib.types.unspecified;
          default = null;
        };

        # Computed
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
    }));
    default = {};
  };

  config.flake = {
    # Populate hosts from discovered host files
    inherit (helpers) hosts;

    # Route system configs to the right flake output per OS
    nixosConfigurations =
      lib.mapAttrs (_: r: r.systemConfig)
      (lib.filterAttrs (n: _: outerConfig.flake.hosts.${n}.os == "nixos") hostResults);

    systemConfigs =
      lib.mapAttrs (_: r: r.systemConfig)
      (lib.filterAttrs (n: _: outerConfig.flake.hosts.${n}.os == "linux") hostResults);

    darwinConfigurations =
      lib.mapAttrs (_: r: r.systemConfig)
      (lib.filterAttrs (n: _: outerConfig.flake.hosts.${n}.os == "darwin") hostResults);

    # Standalone home-manager configurations for all hosts
    homeConfigurations =
      lib.mapAttrs' (
        hostname: hostConfig:
          lib.nameValuePair "${username}@${hostname}" (
            mkStandaloneHome hostname hostConfig
          )
      )
      outerConfig.flake.hosts;
  };
}
