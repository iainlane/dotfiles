# Host configuration evaluation checks.
#
# The profile-contracts check exercises the resolver against fixtures; these
# checks point at the real outputs. Forcing each configuration's toplevel
# drvPath catches a configuration that fails to evaluate, without building the
# host configuration itself.
#
# Each configuration has its own check on its target system. This lets Nix
# evaluate independent configurations concurrently, while `--all-systems`
# still checks every host. The configurations are enumerated from the flake
# outputs, so hosts can come and go without this file changing.
#
# Evaluation reads the private secrets input, so CI needs its deploy key.
# Configurations that use import from derivation also realise those dependencies
# during evaluation.
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
      "adapter-evals: evaluated ${outputName}.${configurationName}"
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
          "adapter-eval-${hostConfig.os}-${hostname}"
          adapter.outputName
          hostname
          (adapter.drvPath configuration)
      )
      hosts;

    homeChecks =
      lib.mapAttrs' (
        hostname: _:
          mkCheck
          "adapter-eval-home-${hostname}"
          "homeConfigurations"
          "${username}@${hostname}"
          config.flake.homeConfigurations."${username}@${hostname}".activationPackage.drvPath
      )
      hosts;
  in {
    checks = systemChecks // homeChecks;
  };
}
