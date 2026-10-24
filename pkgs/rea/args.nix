{
  final,
  inputs,
}: let
  system = final.stdenv.hostPlatform.system;
in {
  nodejs = inputs.nixpkgs-stable.legacyPackages.${system}.nodejs_26;
  upstreamNodejs = inputs.nixpkgs.legacyPackages.${system}.nodejs_24;
  upstreamRea = inputs.nixpkgs.legacyPackages.${system}.rea or null;
}
