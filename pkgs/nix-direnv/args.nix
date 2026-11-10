{
  prev,
  inputs,
  ...
}: {
  upstreamPackage = prev.nix-direnv;
  nixDirenvSource = inputs.nix-direnv;
}
