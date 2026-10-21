# To update: nix run .#update-pi-prs
{callPackage}:
callPackage ../build-support/pi-extension.nix {
  npmName = "pi-prs";
  source = ./source.json;
  npmRoot = ./npm-deps;
  description = "Pull request, review and CI state for Pi";
}
