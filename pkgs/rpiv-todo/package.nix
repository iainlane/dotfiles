# To update: nix run .#update-rpiv-todo
{callPackage}:
callPackage ../build-support/pi-extension.nix {
  npmName = "@juicesharp/rpiv-todo";
  source = ./source.json;
  npmRoot = ./npm-deps;
  description = "A todo list for the model, rendered as a live overlay that survives /reload and conversation compaction";
}
