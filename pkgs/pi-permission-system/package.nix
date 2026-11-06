# To update: nix run .#update-pi-permission-system
{callPackage}:
(callPackage ../build-support/pi-extension.nix {
  npmName = "@gotgenes/pi-permission-system";
  source = ./source.json;
  npmRoot = ./npm-deps;
  description = "Permission enforcement for Pi";
}).overrideAttrs {
  npmFlags = ["--ignore-scripts"];
}
