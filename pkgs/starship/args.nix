{
  prev,
  inputs,
  ...
}: {
  upstreamPackage = prev.starship;
  starshipSource = inputs.starship-custom;
}
