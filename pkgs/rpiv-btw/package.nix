# To update: nix run .#update-rpiv-btw
{callPackage}:
(callPackage ../build-support/pi-extension.nix {
  npmName = "@juicesharp/rpiv-btw";
  source = ./source.json;
  npmRoot = ./npm-deps;
  npmDependencies."@juicesharp/rpiv-config" = "^2.15.0";
  description = "The /btw slash command, for putting a one-off side question to the same primary model without polluting the main conversation";
}).overrideAttrs {
  patches = [./session-isolation.patch ./public-runtime.patch];
}
