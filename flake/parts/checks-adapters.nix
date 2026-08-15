# Host configuration evaluation checks.
#
# The profile-contracts check exercises the resolver against fixtures; this one
# points at the real outputs. Forcing the toplevel drvPath of every host
# configuration (NixOS, nix-darwin, system-manager and standalone Home Manager)
# catches a configuration that fails to evaluate, without building the host
# configurations themselves.
#
# The configurations are enumerated from the flake outputs, so hosts can come
# and go without this file changing. Evaluating them reads the private secrets
# input, so running this check requires access to it (CI passes a deploy key),
# and configurations that import from derivation realise those dependencies
# during evaluation.
{
  config,
  lib,
  ...
}: let
  traceEvaluated = outputName: configurationName: value:
    builtins.deepSeq value (
      builtins.traceVerbose
      "adapter-evals: evaluated ${outputName}.${configurationName}"
      value
    );

  toplevels = outputName: builder:
    lib.mapAttrsToList (
      configurationName: configuration:
        traceEvaluated outputName configurationName (builder configuration)
    );

  drvPaths =
    toplevels "nixosConfigurations" (cfg: cfg.config.system.build.toplevel.drvPath) config.flake.nixosConfigurations
    ++ toplevels "darwinConfigurations" (cfg: cfg.config.system.build.toplevel.drvPath) config.flake.darwinConfigurations
    ++ toplevels "systemConfigs" (cfg: cfg.config.build.toplevel.drvPath) config.flake.systemConfigs
    ++ toplevels "homeConfigurations" (cfg: cfg.activationPackage.drvPath) config.flake.homeConfigurations;
in {
  perSystem = {pkgs, ...}: {
    checks.adapter-evals =
      builtins.deepSeq drvPaths
      (pkgs.runCommandLocal "adapter-evals" {} "touch $out");
  };
}
