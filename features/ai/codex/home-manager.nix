{
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
in {
  programs.codex = {
    enable = true;
    package = wrappedCodex;

    context = instructions.concatenated;
  };
}
