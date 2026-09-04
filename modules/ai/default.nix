{inputs, ...}: let
  # Hands every module of the feature the shared model defaults as an
  # argument. The key keeps a module list that ends up importing it twice
  # from defining the argument twice.
  modelDefaults = {
    key = "dotfiles-ai-model-defaults";
    _module.args.defaultModels = import ./models.nix;
  };
in {
  imports = [
    ./claude-code
    ./claude-desktop
    ./cloudflare-mcp
    ./codex
  ];

  flake.features.ai = {
    system = [modelDefaults];
    homeManager = [
      modelDefaults
      ./unstable-hm-modules.nix
      ./mcp.nix
      ./skills.nix
      ./antigravity-cli.nix
      ./copilot-cli.nix
      ./crush.nix
      ./opencode.nix
      ./opencode2.nix
      ./pi
    ];
  };

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
