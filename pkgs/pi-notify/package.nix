# To update: nix run .#update-pi-notify
{callPackage}:
callPackage ../build-support/pi-extension.nix {
  npmName = "pi-notify";
  source = ./source.json;
  npmRoot = ./npm-deps;
  description = "Desktop notifications for Pi agent via OSC 777/99/9 and Windows toast";
}
