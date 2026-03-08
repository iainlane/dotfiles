_: {
  imports = [
    ./claude-desktop.nix
  ];

  flake.modules.ai.homeManagerModules = [
    ./mcp.nix
    ./claude-code.nix
    ./codex.nix
    ./copilot-cli.nix
    ./crush.nix
    ./gemini-cli.nix
    ./opencode.nix
  ];
}
