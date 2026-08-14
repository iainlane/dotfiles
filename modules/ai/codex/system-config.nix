# This matches the `home-manager` module for Codex.
{
  pkgs,
  lib,
  config,
  hostConfig,
  ...
}: let
  systemConfig = {
    # Updates come from Nix, not codex's self-check.
    check_for_update_on_startup = false;
    features = {
      apps = true;
      memories = true;
      smart_approvals = true;
      undo = true;
    };
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
    model = "gpt-5.6-sol";
    model_reasoning_effort = "high";
    personality = "pragmatic";
    service_tier = "fast";
    suppress_unstable_features_warning = true;
    web_search = "live";
    zsh_path = "${pkgs.zsh}/bin/zsh";
  };

  systemConfigFile = (pkgs.formats.toml {}).generate "codex-system-config.toml" systemConfig;
in {
  imports = [
    (import ../mcp-server-set.nix {
      declareSopsSecrets = false;
      excludedServers = ["codex"];
      secretPath = name: "${hostConfig.homeDirectory}/.config/sops-nix/secrets/${name}";
    })
  ];

  config = {
    environment.etc."codex/config.toml".source = systemConfigFile;
  };
}
