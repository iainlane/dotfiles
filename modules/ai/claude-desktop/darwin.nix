{
  pkgs,
  pkgs-unstable,
  inputs,
  lib,
  ...
}: {
  home.file."Library/Application Support/Claude/claude_desktop_config.json" = {
    # The app itself seems to manage to clobber this file.
    force = true;
    source = import ./config-file.nix {inherit pkgs pkgs-unstable inputs lib;};
  };
}
