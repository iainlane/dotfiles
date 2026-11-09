{
  bash,
  coreutils,
  jq,
  python3,
  runCommandLocal,
  writeShellApplication,
}: {
  # The hook silently skips session reporting when python3 is absent from PATH.
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

  # tui.js imports ../herdr-tui-session.js relative to its real path.
  # Copy both files: symlinks would resolve the import inside Herdr's package.
  # OpenCode silently skips the plugin if that import fails.
  opencodeTuiPlugin = {herdr}:
    runCommandLocal "herdr-opencode-tui-plugin" {} ''
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
  # `herdr plugin unlink` requires a running server; `uninstall` also works
  # offline and does not delete files from linked plugins.
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
