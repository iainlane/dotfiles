# The ai module is not tied to the desktop profile (the work profile pulls it
# in too), so only install the GUI application where the host also has the
# desktop profile.
{
  config,
  pkgs,
  pkgs-unstable,
  inputs,
  hostConfig,
  lib,
  ...
}: let
  helpers = import ../../../lib/helpers.nix {inherit inputs;};
in {
  imports = [./options.nix];

  config = lib.mkIf (helpers.hasProfile hostConfig "desktop") {
    home.packages = [
      inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.claude-desktop
    ];

    xdg.configFile."Claude/claude_desktop_config.json" = {
      # The app itself seems to manage to clobber this file.
      force = true;
      source = import ./config-file.nix {inherit config pkgs pkgs-unstable inputs lib;};
    };
  };
}
