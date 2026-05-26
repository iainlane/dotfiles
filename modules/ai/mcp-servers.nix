{
  pkgs,
  pkgs-unstable,
  inputs,
  lib,
}:
# Define the shared MCP server set once and let each tool consume it.
let
  # The servers every tool should talk to.
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
  mcpServersNix = inputs.mcp-servers-nix.lib.evalModule pkgs-unstable {
    inherit programs;
  };

  # Pull out the computed server definitions for reuse.
  inherit (mcpServersNix.config.settings) servers;

  # These language servers, formatters, and linters are made privately
  # available to the AI tools that can use project diagnostics.
  packages = with pkgs; [
    alejandra
    bash-language-server
    clang-tools # provides clangd
    deadnix
    deno
    ffmpeg
    gopls
    lua-language-server
    marksman
    nil
    pkgs."typescript-language-server"
    pyright
    rust-analyzer
    shellcheck
    shfmt
    statix
    taplo
    yaml-language-server
    yt-dlp
  ];
in {
  inherit packages servers;

  # Helper function to wrap an AI tool with the shared tools in PATH
  wrapWithTools = {
    package,
    binName,
    extraWrapperArgs ? [],
  }: let
    wrapped =
      pkgs.runCommand "${binName}-with-tools" {
        nativeBuildInputs = [pkgs.makeWrapper];
      } ''
        makeWrapper ${package}/bin/${binName} $out/bin/${binName} \
          --prefix PATH : ${lib.makeBinPath packages}${lib.optionalString (extraWrapperArgs != []) " \\\n          ${lib.escapeShellArgs extraWrapperArgs}"}
      '';
  in
    wrapped
    // {
      inherit (package) meta name pname version;
      passthru =
        (package.passthru or {})
        // {
          unwrapped = package;
        };
    };
}
