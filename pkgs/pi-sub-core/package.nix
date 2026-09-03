# To update: nix run .#update-pi-sub-core
{callPackage}:
callPackage ../build-support/pi-extension.nix {
  npmName = "@marckrenn/pi-sub-core";
  source = ./source.json;
  npmRoot = ./npm-deps;
  description = "Shared usage data core for pi extensions";
}
