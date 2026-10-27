{
  final,
  inputs,
}: {
  inherit (inputs.llm-agents.packages.${final.stdenv.hostPlatform.system}) codex;
  claudeCode = inputs.llm-agents.packages.${final.stdenv.hostPlatform.system}.claude-code;
  pkgs = final;
  pythonPackages = import ../../lib/mcp-python.nix {
    inherit inputs;
    pkgs = final;
  };
}
