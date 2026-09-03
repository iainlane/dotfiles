{
  config,
  inputs,
  lib,
  mcp,
  skillTree,
  system,
  ...
}: let
  instructions = import ../agent-instructions.nix {inherit lib;};

  # Codex keeps its skills under `CODEX_HOME`, which the Home Manager module
  # sets when the home prefers XDG directories.
  codexHome =
    config.home.sessionVariables.CODEX_HOME
    or "${config.home.homeDirectory}/.codex";

  # Wrap Codex to add shared tools to PATH.
  wrappedCodex = mcp.wrapWithTools {
    package = inputs.llm-agents.packages.${system}.codex;
    binName = "codex";
  };
in {
  programs.codex = {
    enable = true;
    package = wrappedCodex;

    context = instructions.concatenated;
  };

  home.file."${codexHome}/skills" = {
    source = skillTree config.dotfiles.ai.skills;
    recursive = true;
  };
}
