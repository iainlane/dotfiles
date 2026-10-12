{
  final,
  inputs,
}: {
  pythonPackages = import ../../lib/hermes-python.nix {
    inherit inputs;
    pkgs = final;
  };
}
