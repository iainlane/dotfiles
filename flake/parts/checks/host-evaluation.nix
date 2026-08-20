# Checks that every host configuration evaluates.
#
# Each check forces the top-level derivation path from one configured host
# output. This detects evaluation failures without building the host
# configuration.
#
# Each configuration has a separate check for its target system, so Nix can
# evaluate independent configurations concurrently. Running the flake checks
# with `--all-systems` covers every host. The checks are derived from the flake
# outputs and therefore follow changes to the host inventory.
#
# Evaluation reads the private secrets input, so CI needs its deploy key.
# Configurations that use import from derivation also realise their imported
# derivations during evaluation.
{
  config,
  lib,
  ...
}: let
  inherit (config.dotfiles) username;

  adapters = {
    nixos = {
      outputName = "nixosConfigurations";
      drvPath = configuration: configuration.config.system.build.toplevel.drvPath;
    };
    darwin = {
      outputName = "darwinConfigurations";
      drvPath = configuration: configuration.config.system.build.toplevel.drvPath;
    };
    linux = {
      outputName = "systemConfigs";
      drvPath = configuration: configuration.config.build.toplevel.drvPath;
    };
  };

  traceEvaluated = outputName: configurationName: value:
    builtins.deepSeq value (
      builtins.traceVerbose
      "host-evaluation: evaluated ${outputName}.${configurationName}"
      value
    );
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
        (traceEvaluated outputName configurationName drvPath)
        (pkgs.runCommandLocal checkName {} "touch $out")
      );

    systemChecks =
      lib.mapAttrs' (
        hostname: hostConfig: let
          adapter = adapters.${hostConfig.os};
          configuration = config.flake.${adapter.outputName}.${hostname};
        in
          mkCheck
          "host-evaluation-${hostConfig.os}-${hostname}"
          adapter.outputName
          hostname
          (adapter.drvPath configuration)
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
