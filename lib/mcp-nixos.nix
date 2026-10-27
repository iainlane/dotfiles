{
  inputs,
  pkgs,
}:
inputs.mcp-nixos.lib.mkMcpNixos {
  inherit pkgs;
  python3Packages = import ./mcp-python.nix {inherit inputs pkgs;};
}
