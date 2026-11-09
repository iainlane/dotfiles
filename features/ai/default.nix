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
    ./pi
    ./rea
    ./t3code
  ];

  dotfiles.flakeSystem.includes = [config.dotfiles.features.ai];

  dotfiles.features.ai = {
    inherit (promptOutputs) apps;
    checks = [promptOutputs.checks ./credentials-check.nix ./mcp-server-check.nix ./skill-tree-check.nix];
    # Hosts or features must explicitly include claude-desktop and cloudflare-mcp.
    includes = with children; [
      antigravity-cli
      copilot-cli
      crush
      herdr
      opencode
      pi
      claude-code
      codex
      t3code
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
    # Both host channels use the MCP registry from unstable.
    mcpRegistry = import ./mcp-server-definitions.nix {inherit inputs pkgs;};
  in {
    # Tool wrappers, language servers and mcp-remote follow the host's channel.
    # Harness packages come from llm-agents and are the same on both channels.
    dotfiles.shared = {
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
