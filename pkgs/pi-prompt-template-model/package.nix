# To update: nix run .#update-pi-prompt-template-model
{callPackage}:
callPackage ../build-support/pi-extension.nix {
  npmName = "pi-prompt-template-model";
  source = ./source.json;
  npmRoot = ./npm-deps;
  description = "Prompt template model selector extension for pi coding agent";
}
