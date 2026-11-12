{
  final,
  inputs,
  upstreamPackageSets,
}: {
  inherit (inputs.llm-agents.packages.${final.stdenv.hostPlatform.system}) plannotator-tui;
  inherit (upstreamPackageSets.nixpkgs) rustPlatform;
}
