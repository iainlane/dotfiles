{
  config,
  inputs,
  lib,
  ...
}: let
  host = config.flake.systemConfigs.ancaster.config;
  cfg = host.dotfiles.hermes;
  containers = host.virtualisation.quadlet.containers;
  names = [cfg.container.name cfg.dashboard.containerName];

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
  perSystem = {pkgs, ...}: let
    python = pkgs.python3.withPackages (ps: [ps.ruamel-yaml ps.python-dotenv]);
    managedConfig = (pkgs.formats.yaml {}).generate "hermes-managed-test.yaml" {
      _left_core_installed = ["homeassistant"];
      _left_core_scoped = ["homeassistant"];
      model.default = "nix/model";
      plugins.enabled = ["homeassistant"];
    };
  in {
    checks.hermes-managed-config = assert lib.assertMsg (lib.all usesManagedScope names) "Hermes gateway and dashboard must use managed scope with a writable runtime config";
      pkgs.runCommandLocal "hermes-managed-config-test" {
        nativeBuildInputs = [pkgs.bash pkgs.coreutils python];
      } ''
        export HOME="$TMPDIR/home"
        export HERMES_HOME="$TMPDIR/hermes"
        export HERMES_MANAGED_DIR="$TMPDIR/managed"
        export HERMES_CONTAINER=true
        export HASS_TOKEN=test-not-a-credential
        export PYTHONPATH=${inputs.hermes-agent}
        mkdir -p "$HOME" "$HERMES_HOME" "$HERMES_MANAGED_DIR"
        cp ${managedConfig} "$HERMES_MANAGED_DIR/config.yaml"

        for state in missing empty populated; do
          rm -f "$HERMES_HOME/config.yaml"
          case "$state" in
            empty) touch "$HERMES_HOME/config.yaml" ;;
            populated) printf 'command_allowlist: ["git status"]\n' > "$HERMES_HOME/config.yaml" ;;
          esac
          if [ -e "$HERMES_HOME/config.yaml" ]; then
            cp "$HERMES_HOME/config.yaml" "$TMPDIR/before.yaml"
          else
            touch "$TMPDIR/before.yaml"
          fi
          printf 'nixos\n' > "$HERMES_HOME/.managed"
          bash ${../../../features/hermes/prepare-config.sh} "$HERMES_HOME" "$(id -u):$(id -g)"
          test ! -e "$HERMES_HOME/.managed"
          test -w "$HERMES_HOME/config.yaml"
          cmp "$TMPDIR/before.yaml" "$HERMES_HOME/config.yaml"
          bash ${../../../features/hermes/prepare-config.sh} "$HERMES_HOME" "$(id -u):$(id -g)"
          cmp "$TMPDIR/before.yaml" "$HERMES_HOME/config.yaml"
        done

        python ${../../../features/hermes/config.test.py}
        touch "$out"
      '';
  };
}
