# To update: nix run .#update-pi-footer
{callPackage}:
callPackage ../build-support/pi-extension.nix {
  npmName = "pi-footer";
  source = ./source.json;
  npmRoot = ./npm-deps;
  description = "Configurable, Ultimate multi-line footer/statusline extension for pi";
}
