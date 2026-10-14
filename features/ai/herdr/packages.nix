# The programs that connect Herdr to the agents and to its plugins. Their
# dependencies are function arguments, so the check in
# `flake/parts/checks/herdr.nix` can replace them.
{
  bash,
  coreutils,
  jq,
  python3,
  runCommandLocal,
  writeShellApplication,
}: {
  # Runs the agent-state hook that Herdr ships for `agent`. The hook reports
  # the agent's session to Herdr. It runs `python3` from PATH and exits
  # without reporting anything when PATH has no Python, so the wrapper
  # provides one.
  agentStateHook = {
    herdr,
    agent,
  }:
    writeShellApplication {
      name = "herdr-${agent}-agent-state";

      runtimeInputs = [bash coreutils python3];

      text = ''
        exec bash ${herdr}/share/herdr/integrations/${agent}/herdr-agent-state.sh "$@"
      '';
    };

  # Herdr's TUI plugin for OpenCode 2, as the directory to list in OpenCode 2's
  # `plugins` setting. The plugin's `tui.js` imports `../herdr-tui-session.js`,
  # so that file goes in the parent directory. The files are copies because
  # the import is resolved from the real path of `tui.js`, and a symlink would
  # point it back into Herdr's package. When the import fails, OpenCode 2
  # starts without the plugin and logs no error, so the build checks that
  # `tui.js` still imports that file.
  opencode2TuiPlugin = {herdr}:
    runCommandLocal "herdr-opencode2-tui-plugin" {} ''
      integrations=${herdr}/share/herdr/integrations/opencode

      if ! grep -qF 'from "../herdr-tui-session.js"' "$integrations/tui.js"; then
        echo "Herdr's OpenCode 2 plugin no longer imports ../herdr-tui-session.js" >&2
        exit 1
      fi

      install -Dm444 "$integrations/tui.js" "$out/herdr-opencode/tui.js"
      install -Dm444 "$integrations/herdr-tui-session.js" "$out/herdr-tui-session.js"
    '';

  # Usage: herdr-plugin-sync <store-dir> <plugin-root>...
  #
  # Links each plugin root into Herdr and enables it. Then it removes every
  # linked plugin whose root is under <store-dir> but is not among the
  # arguments. When the configuration stops listing a plugin, the next
  # activation therefore removes it. Plugins linked from outside <store-dir>
  # are left alone.
  #
  # `herdr plugin unlink` fails when no server is running. `herdr plugin
  # uninstall` edits Herdr's plugin registry directly in that case, and it
  # deletes no files of a linked plugin.
  pluginSync = {herdr}:
    writeShellApplication {
      name = "herdr-plugin-sync";

      runtimeInputs = [herdr jq];

      text = ''
        store=''${1%/}/
        shift

        for root in "$@"; do
          herdr plugin link "$root" --enabled >/dev/null
        done

        stale=$(herdr plugin list --json | jq --raw-output --arg store "$store" '
          .result.plugins[]
          | select(.source.kind == "local")
          | select(.plugin_root | startswith($store))
          | select(.plugin_root | IN($ARGS.positional[]) | not)
          | .plugin_id
        ' --args "$@")

        while read -r plugin; do
          [[ -n $plugin ]] || continue
          herdr plugin uninstall "$plugin" >/dev/null
          echo "Removed the Herdr plugin $plugin, which the configuration no longer lists."
        done <<<"$stale"
      '';
    };
}
