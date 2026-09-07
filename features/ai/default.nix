{
  inputs,
  config,
  lib,
  ...
}: let
  children = config.flake.features.ai.provides;

  # Passes the model table to the feature's modules as the `defaultModels`
  # argument. The key lets a module list that imports this twice count it once.
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
    servers = import ./mcp-server-definitions.nix {inherit inputs pkgs;};
  in {
    # A host's channel selects the package set that the tool wrappers, the
    # shared language servers and mcp-remote are built from, so a stable host
    # runs stable tools against the server set above. The harness packages
    # come from the llm-agents input and are the same on either channel.
    _module.args.mcpByChannel = lib.mapAttrs (_: channelPkgs:
      import ./mcp-servers.nix {
        inherit inputs servers;
        inherit (channelPkgs) lib;
        pkgs = channelPkgs;
      }) {
      stable = pkgs-stable;
      unstable = pkgs;
    };
  };
}
