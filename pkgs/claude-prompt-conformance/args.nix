# `package.nix` takes the flake's input set and the package set themselves,
# not a list of individual dependencies, so the overlay passes both.
{
  final,
  inputs,
}: {
  inherit inputs;
  pkgs = final;
}
