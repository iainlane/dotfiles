# To update: nix run .#update-pi-subagents
{callPackage}:
callPackage ../build-support/pi-extension.nix {
  npmName = "pi-subagents";
  source = ./source.json;
  npmRoot = ./npm-deps;
  gitHub = {
    owner = "nicobailon";
    repo = "pi-subagents";
  };
  description = "Pi extension for single-agent delegation and scripted multi-agent workflows";
}
