# Checks that every host configuration evaluates.
#
# Each check forces the top-level derivation path from one configured host
# output. This detects evaluation failures without building the host
# configuration.
#
# Each configuration gets its own check, under the system it is built for,
# so a failure names the host and the output it came from. Running the flake
# checks with `--all-systems` covers every host. The checks are derived from
# the flake outputs and therefore follow changes to the host inventory.
#
# Evaluation reads the private secrets input, so CI needs its deploy key.
# Configurations that use import from derivation also realise their imported
# derivations during evaluation.
{
  config,
  lib,
  ...
}: let
  inherit (config.flake) username;
  operatingSystems = import ../../../lib/operating-systems.nix;

  # The top-level derivation of each kind of system configuration. The OS
  # table names the flake output the configuration is read from.
  drvPathFor = {
    nixos = configuration: configuration.config.system.build.toplevel.drvPath;
    darwin = configuration: configuration.config.system.build.toplevel.drvPath;
    "generic-linux" = configuration: configuration.config.build.toplevel.drvPath;
  };

  traceEvaluating = outputName: configurationName:
    builtins.traceVerbose
    "host-evaluation: evaluating ${outputName}.${configurationName}";
in {
  perSystem = {
    pkgs,
    system,
    ...
  }: let
    hosts = lib.filterAttrs (_: hostConfig: hostConfig.system == system) config.flake.hosts;

    mkCheck = checkName: outputName: configurationName: drvPath:
      lib.nameValuePair checkName (
        builtins.deepSeq
        (traceEvaluating outputName configurationName drvPath)
        (pkgs.runCommandLocal checkName {} "touch $out")
      );

    systemChecks =
      lib.mapAttrs' (
        hostname: hostConfig: let
          inherit (operatingSystems.${hostConfig.os}) outputName;
          configuration = config.flake.${outputName}.${hostname};
        in
          mkCheck
          "host-evaluation-${hostConfig.os}-${hostname}"
          outputName
          hostname
          (drvPathFor.${hostConfig.os} configuration)
      )
      hosts;

    homeChecks =
      lib.mapAttrs' (
        hostname: _:
          mkCheck
          "host-evaluation-home-${hostname}"
          "homeConfigurations"
          "${username}@${hostname}"
          config.flake.homeConfigurations."${username}@${hostname}".activationPackage.drvPath
      )
      hosts;
  in {
    checks = systemChecks // homeChecks;
  };
}
