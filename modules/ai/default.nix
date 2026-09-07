{
  config,
  inputs,
  ...
}: let
  modelDefaults = {
    key = "dotfiles-ai-model-defaults";
    _module.args.defaultModels = config.flake.modules.ai.defaultModels;
  };
in {
  imports = [
    ./claude-code
    ./claude-desktop
    ./cloudflare-mcp
    ./codex
  ];

  flake.modules.ai = {lib, ...}: {
    imports = [
      {
        options.defaultModels = lib.mkOption {
          type = lib.types.attrsOf lib.types.nonEmptyStr;
          description = "Default models by provider.";
        };
      }
    ];
    config = {
      defaultModels = lib.mapAttrs (_: lib.mkDefault) {
        anthropic = "claude-fable-5-1";
        google = "Gemini 3.1 Pro (High)";
        openai = "gpt-6-astra";
      };

      systemManagerModules = [modelDefaults];
      nixosModules = [modelDefaults];
      homeManagerModules = [
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
