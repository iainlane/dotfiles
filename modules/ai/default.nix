_: {
  imports = [
    ./claude-code
    ./claude-desktop
    ./cloudflare-mcp
    ./codex
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
