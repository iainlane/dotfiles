{
  pkgs,
  inputs,
  lib,
}:
# Define the shared MCP server set once and let each tool consume it.
let
  # The servers every tool should talk to.
  programs = {
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

    playwright = {
      enable = true;
      env.PLAYWRIGHT_HTML_OPEN = "false";
    };
  };

  # Evaluate the mcp-servers-nix module to get a computed attrset of MCP server
  # definitions. Each tool module uses `enableMcpIntegration` to pull servers
  # from the shared `programs.mcp` config (set in mcp.nix) rather than
  # consuming this attrset directly. This evaluation is still needed so that
  # mcp.nix can populate `programs.mcp.servers`.
  mcpServersNix = inputs.mcp-servers-nix.lib.evalModule pkgs {
    inherit programs;
  };

  # Pull out the computed server definitions for reuse.
  inherit (mcpServersNix.config.settings) servers;

  # These LSPs are made privately available to the AI tools that support LSP.
  packages = with pkgs; [
    clang-tools # provides clangd
    deno
    gopls
    lua-language-server
    nodePackages.typescript-language-server
    pyright
    rust-analyzer
  ];
in {
  inherit packages servers;

  # Helper function to wrap an AI tool with the shared tools in PATH
  wrapWithTools = {
    package,
    binName,
  }:
    pkgs.symlinkJoin {
      name = "${binName}-with-tools";
      paths = [package];
      nativeBuildInputs = [pkgs.makeWrapper];
      postBuild = ''
        wrapProgram $out/bin/${binName} \
          --prefix PATH : ${lib.makeBinPath packages}
      '';
    };
}
