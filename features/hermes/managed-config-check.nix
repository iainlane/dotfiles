{
  pkgs,
  inputs,
  lib,
  ...
}: let
  scopeFixture = dashboard: let
    container.containerConfig = {
      environments = {
        HERMES_HOME = "/data/.hermes";
        HERMES_MANAGED_DIR = "/etc/hermes";
      };
      volumes = ["/store/config.yaml:/etc/hermes/config.yaml:ro"];
    };
    checks = import ./managed-config-host-check.nix {
      hostConfig.name = "fixture";
      systemConfig = {
        dotfiles.hermes = {
          container.name = "gateway";
          dashboard = {present = dashboard;} // lib.optionalAttrs dashboard {containerName = "dashboard";};
        };
        virtualisation.quadlet.containers = {gateway = container;} // lib.optionalAttrs dashboard {dashboard = container;};
      };
    } {inherit pkgs lib;};
  in
    checks.host-evaluation-hermes-managed-config-fixture.drvPath;
  python = pkgs.python3.withPackages (ps: [ps.ruamel-yaml ps.python-dotenv]);
  managedConfig = (pkgs.formats.yaml {}).generate "hermes-managed-test.yaml" {
    _left_core_installed = ["homeassistant"];
    _left_core_scoped = ["homeassistant"];
    model.default = "nix/model";
    plugins.enabled = ["homeassistant"];
  };
in {
  hermes-managed-config =
    builtins.deepSeq (map scopeFixture [false true])
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
        bash ${./prepare-config.sh} "$HERMES_HOME" "$(id -u):$(id -g)"
        test ! -e "$HERMES_HOME/.managed"
        test -w "$HERMES_HOME/config.yaml"
        cmp "$TMPDIR/before.yaml" "$HERMES_HOME/config.yaml"
        bash ${./prepare-config.sh} "$HERMES_HOME" "$(id -u):$(id -g)"
        cmp "$TMPDIR/before.yaml" "$HERMES_HOME/config.yaml"
      done

      python ${./config.test.py}
      touch "$out"
    '';
}
