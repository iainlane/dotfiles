{
  final,
  upstreamPackageSets,
}: let
  inherit (upstreamPackageSets.nixpkgs) lib nodejs_24;
  minimumNodeVersion = "24.22.1";
  nodejs =
    if lib.versionAtLeast nodejs_24.version minimumNodeVersion
    then nodejs_24
    else upstreamPackageSets.nixpkgs-stable.nodejs_24;
in {
  nodejs = assert lib.assertMsg (lib.versionAtLeast nodejs.version minimumNodeVersion) "REA requires Node ${minimumNodeVersion} or newer."; nodejs;
  installAgentSkills = final.installAgentSkills or upstreamPackageSets.nixpkgs.installAgentSkills;
}
