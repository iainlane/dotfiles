# Checks that every host configuration evaluates.
#
# Each check forces the top-level derivation path from one configured host
# output. This detects evaluation failures without building the host
# configuration.
#
# Each configuration gets its own check, under the system that it is built for,
# so a failure identifies both the host and the output. Running the flake
# checks with `--all-systems` covers every host. The checks are derived from
# the flake outputs and therefore follow changes to the host inventory.
#
# Evaluation reads the private secrets input, so CI needs its deploy key.
# Configurations that use import from derivation also realise their imported
# derivations during evaluation.
{
  config,
  lib,
  hostResults,
  ...
}: let
  inherit (config.flake) username;
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
      lib.nameValuePair checkName (lib.lazyDerivation {
        derivation =
          builtins.deepSeq
          (traceEvaluating outputName configurationName drvPath)
          (pkgs.runCommandLocal checkName {} "touch $out");
        passthru.requiredSystemFeatures = [];
      });

    systemChecks =
      lib.mapAttrs' (
        hostname: hostConfig: let
          inherit (hostResults.${hostname}) outputName toplevel;
        in
          mkCheck
          "host-evaluation-${hostConfig.os}-${hostname}"
          outputName
          hostname
          toplevel.drvPath
      )
      hosts;

    homeChecks =
      lib.mapAttrs' (
        hostname: _:
          mkCheck
          "host-evaluation-home-${hostname}"
          "homeConfigurations"
          "${username}@${hostname}"
          hostResults.${hostname}.homeConfiguration.activationPackage.drvPath
      )
      hosts;
  in {
    checks = systemChecks // homeChecks;
  };
}
