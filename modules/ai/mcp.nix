{
  pkgs,
  pkgs-unstable,
  inputs,
  lib,
  options,
  ...
}: {
  config = lib.optionalAttrs (options ? programs && options.programs ? mcp) {
    programs.mcp = {
      enable = true;
      inherit (import ./mcp-servers.nix {inherit pkgs pkgs-unstable inputs lib;}) servers;
    };
  };
}
