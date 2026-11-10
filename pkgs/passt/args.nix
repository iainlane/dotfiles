{
  prev,
  inputs,
  final,
}: {
  upstreamPackage = prev.passt;
  stablePasst = inputs.nixpkgs-stable.legacyPackages.${final.stdenv.hostPlatform.system}.passt;
}
