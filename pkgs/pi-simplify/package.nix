# Reviews changed code for clarity, consistency, and maintainability through
# the /simplify command.
#
# To update: nix run .#update-pi-simplify
{callPackage}:
callPackage ../build-support/pi-extension.nix {
  npmName = "pi-simplify";
  source = ./source.json;
  npmRoot = ./npm-deps;
  description = "A Pi extension that reviews recently changed code for clarity, consistency, and maintainability.";
}
