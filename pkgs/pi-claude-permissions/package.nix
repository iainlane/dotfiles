# Claude-style permission modes, including a read-only plan mode and Shift+Tab
# mode cycling.
#
# To update: nix run .#update-pi-claude-permissions
{callPackage}:
callPackage ../build-support/pi-extension.nix {
  npmName = "@zackify/pi-claude-permissions";
  source = ./source.json;
  npmRoot = ./npm-deps;
  description = "Claude-style permissions for pi with an opinionated small mode set and built-in plan mode.";
}
