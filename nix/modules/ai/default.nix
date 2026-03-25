_: {
  imports = [
    ./claude-code.nix
    ./claude-desktop.nix
    ./codex.nix
  ];

  flake.modules.ai.homeManagerModules = [
    ./unstable-hm-modules.nix
    ./mcp.nix
    ./copilot-cli.nix
    ./crush.nix
    ./gemini-cli.nix
    ./opencode.nix
  ];
}
