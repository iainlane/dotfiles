# To update: nix run .#update-pi-pretty
{callPackage}:
callPackage ../build-support/pi-extension.nix {
  npmName = "@heyhuynhgiabuu/pi-pretty";
  source = ./source.json;
  npmRoot = ./npm-deps;
  description = "Terminal output for pi with syntax-highlighted file reads, coloured bash output and directory trees";
}
