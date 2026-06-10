_: {
  imports = [
    ./claude-code.nix
    ./claude-desktop.nix
    ./codex.nix
  ];

  flake.modules.ai.homeManagerModules = [
    ./unstable-hm-modules.nix
    ./mcp.nix
    ./antigravity-cli.nix
    ./copilot-cli.nix
    ./crush.nix
    ./opencode.nix
    ./pi
  ];
}
