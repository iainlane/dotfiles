# The MCP servers every harness should talk to, and the mcp-servers-nix module
# evaluation that turns them into server definitions.
#
# `features/ai/default.nix` calls this once per system, against unstable, and
# gives the result to `mcp-servers.nix` for both channels. The definitions are
# therefore built from unstable even on a stable host; `mcp-servers.nix`
# supplies the channel-specific tools around them.
{
  inputs,
  pkgs,
}: let
  inherit (pkgs) lib;
  programs = {
    codex = {
      enable = true;
      package = inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.codex;
    };

    context7.enable = true;

    fetch.enable = false;

    git.enable = true;

    github = {
      enable = false;
      package = pkgs.github-mcp-server;
      passwordCommand = {
        GITHUB_PERSONAL_ACCESS_TOKEN = ["gh" "auth" "token"];
      };
    };

    nixos = {
      enable = true;
      # mcp-nixos checks for updates on startup, which is slow and noisy; turn
      # it off so the server comes up quickly.
      env.FASTMCP_CHECK_FOR_UPDATES = "off";
    };

    playwright = {
      enable = true;
      env.PLAYWRIGHT_HTML_OPEN = "false";
    };
  };

  mcpServersNix = inputs.mcp-servers-nix.lib.evalModule pkgs {
    inherit programs;
  };
in {
  inherit (mcpServersNix.config.settings) servers;
  serverPackages = lib.mapAttrs (name: _: mcpServersNix.config.programs.${name}.package) mcpServersNix.config.settings.servers;
}
