{
  prev,
  inputs,
  ...
}: {
  upstreamPackage = prev.caddy;
  channel =
    if toString prev.path == inputs.nixpkgs-stable.outPath
    then "stable"
    else "unstable";
}
