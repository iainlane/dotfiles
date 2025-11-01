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
  # definitions. By evaluating once here and extracting `servers`, we avoid
  # repeating the server configuration in every AI tool module. Each tool then
  # imports this file and either:
  # 1. Uses `servers` directly (if the tool's home-manager module supports it)
  # 2. Calls `mkConfigFile` to generate a config file in the format the tool
  #    expects
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

  # Build a config file for tools that can't consume `servers` directly.
  # `flavor` selects the tool's schema (e.g. "claude", "codex"), `format` picks
  # the serialisation ("json", "toml-inline"), and `fileName` is the output
  # path. This is necessary because some tools expect a path to a config file
  # rather than accepting configuration programmatically.
  mkConfigFile = flavor: format: fileName:
    inputs.mcp-servers-nix.lib.mkConfig pkgs {
      inherit
        flavor
        format
        fileName
        ;
      inherit programs;
    };

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
