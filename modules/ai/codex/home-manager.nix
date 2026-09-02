{
  inputs,
  lib,
  mcp,
  system,
  ...
}: let
  instructions = import ../agent-instructions.nix {inherit lib;};
  skills = import ../skills.nix {inherit inputs lib;};

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

    # Shared skills from ./skills/.
    inherit skills;
  };
}
