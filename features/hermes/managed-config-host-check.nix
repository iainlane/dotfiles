{
  hostConfig,
  systemConfig,
}: {
  pkgs,
  lib,
  ...
}: let
  cfg = systemConfig.dotfiles.hermes;
  containers = systemConfig.virtualisation.quadlet.containers;
  names = [cfg.container.name] ++ lib.optional cfg.dashboard.present cfg.dashboard.containerName;

  usesManagedScope = name: let
    container = containers.${name}.containerConfig;
    managedEnvironment = lib.filterAttrs (key: _: builtins.elem key ["HERMES_HOME" "HERMES_MANAGED" "HERMES_MANAGED_DIR"]) container.environments;
    configTargets = map (mount: lib.concatStringsSep ":" (builtins.tail (lib.splitString ":" mount))) (
      lib.filter (mount: lib.hasInfix "/config.yaml" mount) container.volumes
    );
  in
    managedEnvironment
    == {
      HERMES_HOME = "/data/.hermes";
      HERMES_MANAGED_DIR = "/etc/hermes";
    }
    && configTargets == ["/etc/hermes/config.yaml:ro"];
in {
  "host-evaluation-hermes-managed-config-${hostConfig.name}" = lib.lazyDerivation {
    derivation = assert lib.assertMsg (lib.all usesManagedScope names) "Hermes containers must use managed scope with a writable runtime config";
      pkgs.runCommandLocal "hermes-managed-scope" {} "touch $out";
    passthru.requiredSystemFeatures = [];
  };
}
