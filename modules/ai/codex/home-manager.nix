{
  pkgs,
  pkgs-unstable,
  inputs,
  lib,
  system,
  ...
}: let
  mcp = import ../mcp-servers.nix {inherit pkgs pkgs-unstable inputs lib;};
  instructions = import ../agent-instructions.nix {inherit lib;};
  skills = import ../skills.nix {inherit lib;};

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
