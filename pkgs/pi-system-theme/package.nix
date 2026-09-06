# Cross-platform auto dark/light switcher. On Linux it polls `gsettings get
# org.gnome.desktop.interface color-scheme` every `pollMs`; on macOS it reads
# `AppleInterfaceStyle`. On both platforms the extension accepts custom theme
# names via `~/.pi/agent/system-theme.json`, which lets the Pi module map the
# detected mode to the matching Catppuccin theme it renders.
#
# To update: nix run .#update-pi-system-theme
{callPackage}:
callPackage ../build-support/pi-extension.nix {
  npmName = "pi-system-theme";
  source = ./source.json;
  npmRoot = ./npm-deps;
  description = "Sync Pi theme with macOS light/dark appearance";
}
