{
  config,
  inputs,
  instructions,
  mcp,
  system,
  ...
}: let
  wrappedCodex = mcp.wrapWithTools {
    package = inputs.llm-agents.packages.${system}.codex;
    binName = "codex";
  };

  codexHome =
    config.home.sessionVariables.CODEX_HOME
      or "${config.home.homeDirectory}/.codex";
in {
  programs.codex = {
    enable = true;
    package = wrappedCodex;

    context = instructions.concatenated;
  };

  # The background daemon runs `current/bin/codex` from this directory. When
  # the link is missing, codex tries to copy its own package here, which only
  # an upstream install layout supports. Codex writes the link itself on that
  # path, so `force` lets the next switch replace it.
  home.file."${codexHome}/packages/app-server-daemon/current" = {
    source = wrappedCodex;
    force = true;
  };
}
