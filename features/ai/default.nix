{
  inputs,
  config,
  lib,
  ...
}: let
  promptOutputs = import ./prompt-conformance.nix {
    inherit inputs lib;
    inherit (config.dotfiles) modelCatalog;
  };
  children = config.dotfiles.features.ai;
in {
  imports = [
    ./model-catalogue.nix
    ./antigravity-cli
    ./claude-code
    ./claude-desktop
    ./cloudflare-mcp
    ./codex
    ./copilot-cli
    ./crush
    ./herdr
    ./opencode
    ./opencode2
    ./pi
    ./rea
  ];

  dotfiles.flakeSystem.includes = [config.dotfiles.features.ai];

  dotfiles.features.ai = {
    inherit (promptOutputs) apps;
    checks = [promptOutputs.checks ./credentials-check.nix ./mcp-server-check.nix ./skill-tree-check.nix];
    # One child per harness. `claude-desktop` and `cloudflare-mcp` are not
    # here: a feature or a host that wants them lists them.
    includes = with children; [
      antigravity-cli
      copilot-cli
      crush
      herdr
      opencode
      opencode2
      pi
      claude-code
      codex
    ];

    homeManager = [
      ./provider-credentials.nix
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
    _module.args = {
      inherit mcpRegistry;
      mcpByChannel = lib.mapAttrs (_: channelPkgs:
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
  };
}
