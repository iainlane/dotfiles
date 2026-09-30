{
  instructions,
  mcp,
  pkgs,
  ...
}: let
  wrappedCodex = mcp.wrapWithTools {
    package = pkgs.codex;
    binName = "codex";
  };
in {
  programs.codex = {
    enable = true;
    package = wrappedCodex;

    context = instructions.concatenated;
  };
}
