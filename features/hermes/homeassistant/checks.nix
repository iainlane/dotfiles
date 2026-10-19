{
  hostConfig,
  systemConfig,
  ...
}: {
  pkgs,
  inputs,
  lib,
  system,
  ...
}: let
  cfg = systemConfig.dotfiles.hermes;
  settings = lib.filterAttrs (name: _:
    builtins.elem name [
      "_left_core_installed"
      "_left_core_scoped"
      "known_plugin_toolsets"
      "platform_toolsets"
    ])
  cfg.settings;
in {
  "host-evaluation-hermes-homeassistant-${hostConfig.name}" = let
    hermes = import ../../../lib/hermes-package.nix {inherit inputs system;};
    configuration = (pkgs.formats.yaml {}).generate "hermes-homeassistant-test.yaml" (settings
      // {
        plugins.enabled = ["homeassistant"];
        updates.check = false;
      });
    plugin = cfg.extraPlugins.homeassistant or null;
  in
    pkgs.runCommand "hermes-homeassistant-test" {} ''
      export HOME="$TMPDIR/home"
      export HERMES_HOME="$TMPDIR/hermes"
      export HERMES_MANAGED_DIR="$TMPDIR/managed"
      export HASS_TOKEN=test-not-a-credential
      mkdir -p "$HOME" "$HERMES_HOME/plugins" "$HERMES_HOME/cron" \
        "$HERMES_HOME/sessions" "$HERMES_HOME/logs" "$HERMES_HOME/memories"
      mkdir -p "$HERMES_MANAGED_DIR"
      cp ${configuration} "$HERMES_MANAGED_DIR/config.yaml"
      touch "$HERMES_HOME/config.yaml"
      ${lib.optionalString (plugin != null) ''
        ln -s ${lib.escapeShellArg (toString plugin)} "$HERMES_HOME/plugins/nix-managed-homeassistant"
      ''}
      ${hermes.hermesVenv}/bin/python3 \
        ${./migration.test.py} ${hermes}
      touch "$out"
    '';
}
