# This matches the `home-manager` module for Codex.
{
  pkgs,
  pkgs-unstable,
  inputs,
  lib,
  config,
  ...
}: let
  mcp = import ../mcp-servers.nix {inherit pkgs pkgs-unstable inputs lib;};

  managedConfig = {
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
    model = "gpt-5.5";
    model_reasoning_effort = "high";
    personality = "pragmatic";
    service_tier = "fast";
    suppress_unstable_features_warning = true;
    web_search = "live";
    zsh_path = "${pkgs.zsh}/bin/zsh";
  };

  managedConfigFile = (pkgs.formats.toml {}).generate "codex-managed-config.toml" managedConfig;
in {
  # This is the system/NixOS copy of the shared MCP option. The Home Manager
  # copy is declared in mcp.nix for the interactive tools; Codex's managed
  # config lives under /etc, so it needs the same option surface here.
  options.dotfiles.ai.mcpServers = mcp.mcpServersOption;

  config = {
    # Base shared servers. Codex never runs itself as an MCP server, so drop
    # the `codex` entry.
    dotfiles.ai.mcpServers = lib.removeAttrs mcp.servers ["codex"];

    environment.etc."codex/managed_config.toml".source = managedConfigFile;
  };
}
