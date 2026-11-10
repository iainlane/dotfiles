{
  inputs,
  final,
}: {
  upstreamPackage = inputs.llm-agents.packages.${final.stdenv.hostPlatform.system}.pi;
}
