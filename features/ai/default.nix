{
  inputs,
  config,
  ...
}: let
  children = config.flake.features.ai.provides;

  # Hands every module of the feature the shared model defaults as an
  # argument. The key keeps a module list that ends up importing it twice
  # from defining the argument twice.
  modelDefaults = {
    key = "dotfiles-ai-model-defaults";
    _module.args.defaultModels = import ./models.nix;
  };
in {
  imports = [
    ./antigravity-cli
    ./claude-code
    ./claude-desktop
    ./cloudflare-mcp
    ./codex
    ./copilot-cli
    ./crush
    ./opencode
    ./opencode2
    ./pi
  ];

  flake.features.ai = {
    # One child per harness. `claude-desktop` and `cloudflare-mcp` are not
    # here: a feature or a host that wants them lists them.
    includes = with children; [
      antigravity-cli
      copilot-cli
      crush
      opencode
      opencode2
      pi
      claude-code
      codex
    ];

    system = [modelDefaults];

    homeManager = [
      modelDefaults
      ./unstable-hm-modules.nix
      ./mcp.nix
      ./skills.nix
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
