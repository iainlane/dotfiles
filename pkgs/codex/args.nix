{
  final,
  inputs,
}: {
  inherit (inputs.llm-agents.packages.${final.stdenv.hostPlatform.system}) codex;
}
