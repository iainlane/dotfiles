{
  final,
  upstreamPackageSets,
}: {
  nodejs = upstreamPackageSets.nixpkgs-stable.nodejs_24;
  upstreamNodejs = upstreamPackageSets.nixpkgs.nodejs_24;
  upstreamRea = upstreamPackageSets.nixpkgs.rea or null;
  installAgentSkills = final.installAgentSkills or upstreamPackageSets.nixpkgs.installAgentSkills;
}
