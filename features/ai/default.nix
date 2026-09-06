{
  inputs,
  config,
  lib,
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
    # A host's channel selects the package set its harnesses, language servers
    # and mcp-remote are built from. The server definitions come from
    # mcp-servers-nix evaluated against unstable on both channels, so a stable
    # host runs stable tools against the current server set.
    _module.args.mcpByChannel = lib.mapAttrs (_: channelPkgs:
      import ./mcp-servers.nix {
        inherit inputs;
        inherit (channelPkgs) lib;
        pkgs = channelPkgs;
        pkgs-unstable = pkgs;
      }) {
      stable = pkgs-stable;
      unstable = pkgs;
    };
  };
}
