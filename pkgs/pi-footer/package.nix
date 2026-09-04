# To update: nix run .#update-pi-footer
{callPackage}:
callPackage ../build-support/pi-extension.nix {
  npmName = "pi-footer";
  source = ./source.json;
  npmRoot = ./npm-deps;
  gitHub = {
    owner = "wobondar";
    repo = "pi-footer";
  };
  description = "Configurable multiline footer and status line for pi";
}
