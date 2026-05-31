{
  config,
  lib,
  ...
}: {
  options.services.hermes-agent = {
    enable = lib.mkEnableOption "Hermes Agent gateway service";

    package = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "${config.xdg.stateHome}/hermes";
    };

    workingDirectory = lib.mkOption {
      type = lib.types.str;
      default = "${config.services.hermes-agent.stateDir}/workspace";
    };

    settings = lib.mkOption {
      type = lib.types.attrs;
      default = {};
    };

    environment = lib.mkOption {
      type = with lib.types; attrsOf str;
      default = {};
    };

    environmentFiles = lib.mkOption {
      type = with lib.types; listOf str;
      default = [];
    };

    extraArgs = lib.mkOption {
      type = with lib.types; listOf str;
      default = [];
    };

    extraDependencyGroups = lib.mkOption {
      type = with lib.types; listOf str;
      default = ["messaging"];
    };

    extraPackages = lib.mkOption {
      type = with lib.types; listOf package;
      default = [];
    };

    container = {
      image = lib.mkOption {
        type = lib.types.str;
        default = "docker.io/library/ubuntu:24.04";
      };

      name = lib.mkOption {
        type = lib.types.str;
        default = "hermes-agent";
      };

      network = lib.mkOption {
        type = with lib.types; either str (listOf str);
        default = [];
      };

      ports = lib.mkOption {
        type = with lib.types; listOf str;
        default = [];
      };

      extraVolumes = lib.mkOption {
        type = with lib.types; listOf str;
        default = [];
      };

      extraPodmanArgs = lib.mkOption {
        type = with lib.types; listOf str;
        default = [];
      };
    };
  };
}
