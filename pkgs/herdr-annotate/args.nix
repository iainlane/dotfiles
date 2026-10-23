{
  final,
  inputs,
}: {
  inherit (inputs.llm-agents.packages.${final.stdenv.hostPlatform.system}) plannotator-tui;
  inherit (inputs.nixpkgs.legacyPackages.${final.stdenv.hostPlatform.system}) rustPlatform;
}
