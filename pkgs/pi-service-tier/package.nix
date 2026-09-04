# To update: nix run .#update-pi-service-tier
{callPackage}:
callPackage ../build-support/pi-extension.nix {
  npmName = "pi-service-tier";
  source = ./source.json;
  npmRoot = ./npm-deps;
  gitHub = {
    owner = "mavam";
    repo = "pi-service-tier";
  };
  description = "Fast mode and provider service-tier controls for pi";
}
