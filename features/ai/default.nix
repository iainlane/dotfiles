{
  inputs,
  config,
  lib,
  ...
}: let
  children = config.flake.features.ai.provides;
  modelCatalog = import ./models.nix;

  # The key prevents duplicate imports from applying this module twice.
  modelDefaults = {
    key = "dotfiles-ai-model-defaults";
    _module.args = {
      inherit modelCatalog;
      defaultModels = modelCatalog.defaults;
    };
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
    ./prompt-conformance.nix
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
      ./prose-lint.nix
      ./skills.nix
    ];
  };

  perSystem = {
    pkgs,
    pkgs-stable,
    ...
  }: let
    # The mcp-servers-nix module system is evaluated once per system, against
    # unstable, and both channels are given the result. The server definitions
    # are therefore built from unstable even on a stable host.
    mcpRegistry = import ./mcp-server-definitions.nix {inherit inputs pkgs;};
  in {
    # A host's channel selects the package set that the tool wrappers, the
    # shared language servers and mcp-remote are built from, so a stable host
    # runs stable tools against the server set above. The harness packages
    # come from the llm-agents input and are the same on either channel.
    _module.args.mcpByChannel = lib.mapAttrs (_: channelPkgs:
      import ./mcp-servers.nix {
        inherit inputs;
        inherit (mcpRegistry) servers serverPackages;
        inherit (channelPkgs) lib;
        pkgs = channelPkgs;
      }) {
      stable = pkgs-stable;
      unstable = pkgs;
    };
  };
}
