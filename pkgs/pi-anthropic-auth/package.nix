# To update: nix run .#update-pi-anthropic-auth
{callPackage}:
callPackage ../build-support/pi-extension.nix {
  npmName = "@gotgenes/pi-anthropic-auth";
  source = ./source.json;
  npmRoot = ./npm-deps;
  description = "Anthropic OAuth compatibility for Pi";
}
