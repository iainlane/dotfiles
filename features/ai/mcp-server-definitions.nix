# Shared MCP servers and the mcp-servers-nix evaluation that defines them.
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
    context7.enable = true;

    fetch.enable = false;

    git = {
      enable = true;
      package = pkgs.mcp-server-git;
    };

    github = {
      enable = false;
      package = pkgs.github-mcp-server;
      passwordCommand = {
        GITHUB_PERSONAL_ACCESS_TOKEN = ["gh" "auth" "token"];
      };
    };

    nixos = {
      enable = true;
      package = import ../../lib/mcp-nixos.nix {inherit inputs pkgs;};
      # mcp-nixos checks for updates on startup, which is slow and noisy; turn
      # it off so the server comes up quickly.
      env.FASTMCP_CHECK_FOR_UPDATES = "off";
    };

    playwright = {
      enable = true;
      env.PLAYWRIGHT_HTML_OPEN = "false";
    };
  };

  # `evalModule` applies two overlays with `pkgs.extend`, which instantiates
  # nixpkgs again for each one. Both overlays only add attributes, so apply them
  # to the shared set as an attribute set update. This stays correct while no
  # package in the overlays takes another as a `callPackage` argument, because
  # `pkgs.callPackage` resolves arguments from the shared set.
  pkgsWithOverlayUpdate =
    pkgs
    // {
      extend = overlay: let
        final = pkgs // overlay final pkgs;
      in
        final;
    };

  mcpServersNix = inputs.mcp-servers-nix.lib.evalModule pkgsWithOverlayUpdate {
    inherit programs;
  };
in {
  inherit (mcpServersNix.config.settings) servers;
  serverPackages = lib.mapAttrs (name: _: mcpServersNix.config.programs.${name}.package) mcpServersNix.config.settings.servers;
}
