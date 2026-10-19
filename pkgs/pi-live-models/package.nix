# To update: nix run .#update-pi-live-models
{callPackage}:
(callPackage ../build-support/pi-extension.nix {
  npmName = "pi-live-models";
  source = ./source.json;
  npmRoot = ./npm-deps;
  description = "Live model discovery for Pi from provider endpoints";
}).overrideAttrs {
  patches = [./offline-refresh.patch ./openrouter-cache-pricing.patch];
}
