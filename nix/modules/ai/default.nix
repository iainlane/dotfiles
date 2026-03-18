_: {
  imports = [
    ./claude-code.nix
    ./claude-desktop.nix
  ];

  flake.modules.ai.homeManagerModules = [
    ./unstable-hm-modules.nix
    ./mcp.nix
    ./codex.nix
    ./copilot-cli.nix
    ./crush.nix
    ./gemini-cli.nix
    ./opencode.nix
  ];
}
