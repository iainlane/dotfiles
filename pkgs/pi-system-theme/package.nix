# To update: nix run .#update-pi-system-theme
{callPackage}:
callPackage ../build-support/pi-extension.nix {
  npmName = "pi-system-theme";
  source = ./source.json;
  npmRoot = ./npm-deps;
  description = "Sync Pi theme with macOS light/dark appearance";
}
