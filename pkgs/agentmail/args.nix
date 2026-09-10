{
  final,
  inputs,
}: {
  pythonPackages = import ../../lib/hermes-python.nix {
    inherit inputs;
    inherit (final) lib;
    pkgs = final;
  };
}
