{
  pkgs,
  inputs,
  lib,
  ...
}: let
  mcp = import ./mcp-servers.nix {inherit pkgs inputs lib;};
in {
  programs.mcp = {
    enable = true;
    inherit (mcp) servers;
  };
}
