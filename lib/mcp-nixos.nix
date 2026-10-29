{
  inputs,
  pkgs,
}:
inputs.mcp-nixos.lib.mkMcpNixos {
  inherit pkgs;
  python3Packages = pkgs.mcpPythonPackages;
}
