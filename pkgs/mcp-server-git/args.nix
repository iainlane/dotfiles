{
  inputs,
  final,
}: {
  pythonPackages = import ../../lib/mcp-python.nix {
    inherit inputs;
    pkgs = final;
  };
}
