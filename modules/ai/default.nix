{inputs, ...}: {
  imports = [
    ./claude-code
    ./claude-desktop
    ./cloudflare-mcp
    ./codex
  ];

  flake.modules.ai.homeManagerModules = [
    ./unstable-hm-modules.nix
    ./mcp.nix
    ./skill-set.nix
    ./antigravity-cli.nix
    ./copilot-cli.nix
    ./crush.nix
    ./opencode.nix
    ./opencode2.nix
    ./pi
  ];

  perSystem = {
    pkgs,
    pkgs-stable,
    ...
  }: {
    _module.args.mcpByChannel = {
      stable = import ./mcp-servers.nix {
        inherit inputs;
        inherit (pkgs-stable) lib;
        pkgs = pkgs-stable;
        pkgs-unstable = pkgs;
      };
      unstable = import ./mcp-servers.nix {
        inherit inputs pkgs;
        inherit (pkgs) lib;
        pkgs-unstable = pkgs;
      };
    };
  };
}
