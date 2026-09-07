# `package.nix` uses enough of nixpkgs to take the package set itself, and it
# drives the two agent clients this flake pins, which come from `llm-agents`
# and not from the package set.
{
  final,
  inputs,
}: {
  inherit (inputs.llm-agents.packages.${final.stdenv.hostPlatform.system}) codex;
  claudeCode = inputs.llm-agents.packages.${final.stdenv.hostPlatform.system}.claude-code;
  pkgs = final;
}
