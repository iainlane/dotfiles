{
  inputs,
  final,
}: {
  upstreamPi = inputs.llm-agents.packages.${final.stdenv.hostPlatform.system}.pi;
}
