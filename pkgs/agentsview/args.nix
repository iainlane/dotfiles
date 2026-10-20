{
  final,
  inputs,
}: let
  unstable = inputs.nixpkgs.legacyPackages.${final.stdenv.hostPlatform.system};
in {
  inherit (inputs.llm-agents.packages.${final.stdenv.hostPlatform.system}) agentsview;
  inherit (unstable) fetchFromGitHub fetchNpmDeps;
}
