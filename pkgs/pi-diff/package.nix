# To update: nix run .#update-pi-diff
{callPackage}:
(callPackage ../build-support/pi-extension.nix {
  npmName = "@heyhuynhgiabuu/pi-diff";
  source = ./source.json;
  npmRoot = ./npm-deps;
  description = "Syntax-highlighted terminal diffs for Pi file edits and writes";
}).overrideAttrs {
  patches = [./host-sdk-imports.patch];
}
