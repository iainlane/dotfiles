{
  pkgs,
  inputs,
  lib,
  options,
  ...
}: {
  config = lib.optionalAttrs (options ? programs && options.programs ? mcp) {
    programs.mcp = {
      enable = true;
      inherit (import ./mcp-servers.nix {inherit pkgs inputs lib;}) servers;
    };
  };
}
