# Cross-platform auto dark/light switcher. On Linux it polls `gsettings get
# org.gnome.desktop.interface color-scheme` every `pollMs`; on macOS it reads
# `AppleInterfaceStyle`. The extension accepts custom theme names on either
# platform, through `~/.pi/agent/system-theme.json`, so the Pi module can map
# the detected mode to the matching Catppuccin theme that it renders.
#
# To update: nix run .#update-pi-system-theme
{callPackage}:
callPackage ../build-support/pi-extension.nix {
  npmName = "pi-system-theme";
  source = ./source.json;
  npmRoot = ./npm-deps;
  description = "Sync Pi theme with macOS light/dark appearance";
}
