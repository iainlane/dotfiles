# To update: nix run .#update-pi-ask-user
{callPackage}:
callPackage ../build-support/pi-extension.nix {
  npmName = "pi-ask-user";
  source = ./source.json;
  npmRoot = ./npm-deps;
  description = "Interactive questions with choices and free-text answers for Pi";
}
