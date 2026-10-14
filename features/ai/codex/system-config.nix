# Codex's system-wide defaults, written to `/etc/codex/config.toml`. The
# home configuration and each instance's own config override them.
{
  pkgs,
  lib,
  config,
  defaultModels,
  hostConfig,
  ...
}: let
  systemConfig = {
    approvals_reviewer = "auto_review";
    # Updates come from Nix, not codex's self-check.
    check_for_update_on_startup = false;
    features = {
      analytics_plan_history = true;
      apps = true;
      memories = true;
    };
    inherit (config.dotfiles.codex) hooks;
    mcp_servers =
      lib.mapAttrs (
        _name: server: let
          url = server.url or null;
          headers = server.headers or {};
          httpHeaders = server.http_headers or null;
          hasRemoteHeaders =
            url
            != null
            && headers != {}
            && httpHeaders == null;
        in
          (lib.removeAttrs server [
            "disabled"
            "headers"
          ])
          // (lib.optionalAttrs hasRemoteHeaders {
            http_headers = headers;
          })
          // {
            enabled = !(server.disabled or false);
          }
      )
      config.dotfiles.ai.mcpServers;
    model = defaultModels.openai;
    model_reasoning_effort = "high";
    personality = "pragmatic";
    service_tier = "fast";
    suppress_unstable_features_warning = true;
    web_search = "live";
  };

  systemConfigFile = (pkgs.formats.toml {}).generate "codex-system-config.toml" systemConfig;
in {
  imports = [
    (import ../mcp-server-set.nix {
      declareSopsSecrets = false;
      # A system module cannot read the user's home-manager configuration, so
      # the path is written out here. It has to stay equal to
      # `sops.defaultSymlinkPath` in that configuration. No module in this
      # repository sets that option, so it keeps sops-nix's default of
      # `xdg.configHome` plus `sops-nix/secrets`.
      secretPath = name: "${hostConfig.homeDirectory}/.config/sops-nix/secrets/${name}";
    })
  ];

  options.dotfiles.codex.hooks = lib.mkOption {
    type = with lib.types; attrsOf (listOf (attrsOf anything));
    default = {};
    description = ''
      Codex hooks by event, in the format that Codex shares with Claude Code.
      They are written to `/etc/codex/config.toml`, and Codex runs hooks from
      its system configuration without asking for them to be trusted. A
      module adds hooks by defining this option, and the hook groups of each
      event are concatenated.
    '';
  };

  config = {
    dotfiles.codex.hooks = import ../prose-lint-hooks.nix {inherit lib pkgs;};

    environment.etc."codex/config.toml".source = systemConfigFile;
  };
}
