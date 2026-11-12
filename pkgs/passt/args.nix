{
  prev,
  upstreamPackageSets,
}: {
  upstreamPackage = prev.passt;
  stablePasst = upstreamPackageSets.nixpkgs-stable.passt;
}
