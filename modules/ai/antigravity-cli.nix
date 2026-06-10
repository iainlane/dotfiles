# Configure the Antigravity CLI home-manager module with the shared MCP servers.
#
# The module exposes the MCP servers through its own `mcpServers` option and
# writes them to `~/.gemini/config/mcp_config.json`, so we hand it the shared
# set directly.
#
# The CLI rewrites `~/.gemini/antigravity-cli/settings.json` on every launch, so
# it cannot live as a read-only store symlink: the first-run wizard, and every
# later settings write, fail with a permission error. It also has no managed or
# system settings layer to supply values through. Instead an activation step
# deep-merges the Nix-managed keys over the live, writable file, so Nix stays
# authoritative for those keys while the CLI keeps ownership at runtime.
{
  pkgs,
  pkgs-unstable,
  config,
  inputs,
  lib,
  system,
  ...
}: let
  mcp = import ./mcp-servers.nix {inherit pkgs pkgs-unstable inputs lib;};
  instructions = import ./agent-instructions.nix {inherit lib;};
  skills = import ./skills.nix {inherit lib;};

  # Wrap Antigravity CLI to add shared tools to PATH
  wrappedAntigravity = mcp.wrapWithTools {
    package = inputs.llm-agents.packages.${system}.antigravity-cli;
    binName = "agy";
  };

  # Keys the CLI persists in `settings.json`. The model is stored as its
  # display-name string, the same value shown in `agy models` and the `/model`
  # picker. `onboardingComplete` and `securityAgreed` skip the first-run wizard
  # that otherwise blocks at the welcome screen, and `enableTelemetry = false`
  # declines interaction-data collection.
  managedSettings = {
    colorScheme = "terminal";
    model = "Gemini 3.1 Pro (High)";
    onboardingComplete = true;
    securityAgreed = true;
    enableTelemetry = false;
    context.fileName = map (n: "${n}.md") (lib.attrNames instructions.files);
  };

  managedSettingsFile = (pkgs.formats.json {}).generate "antigravity-cli-settings.json" managedSettings;

  settingsPath = "${config.home.homeDirectory}/.gemini/antigravity-cli/settings.json";
in {
  config = {
    programs.antigravity-cli = {
      enable = true;
      package = wrappedAntigravity;

      inherit (config.dotfiles.ai) mcpServers;

      # Shared instructions as separate context files.
      context = instructions.files;

      # Shared skills from ./skills/.
      inherit skills;
    };

    home.activation.antigravityCliSettings = lib.hm.dag.entryAfter ["writeBoundary"] ''
      settingsFile=${lib.escapeShellArg settingsPath}

      $DRY_RUN_CMD mkdir -p "$(dirname "$settingsFile")"

      # Replace any read-only store symlink left by an earlier generation.
      if [ -L "$settingsFile" ]; then
        $DRY_RUN_CMD rm -f "$settingsFile"
      fi

      if [ -f "$settingsFile" ] && ${pkgs.jq}/bin/jq -e . "$settingsFile" >/dev/null 2>&1; then
        $DRY_RUN_CMD ${pkgs.bash}/bin/bash -c \
          "${pkgs.jq}/bin/jq -s '.[0] * .[1]' \"$settingsFile\" ${managedSettingsFile} > \"$settingsFile.hm-new\" && mv \"$settingsFile.hm-new\" \"$settingsFile\""
      else
        $DRY_RUN_CMD cp ${managedSettingsFile} "$settingsFile"
      fi

      $DRY_RUN_CMD chmod u+w "$settingsFile"
    '';
  };
}
