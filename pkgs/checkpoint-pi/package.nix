# Git-ref snapshots of the working tree at every agent turn, with restore
# commands for files+conversation, conversation only, or files only. Cheap undo
# when the agent wanders off-track.
#
# To update: nix run .#update-checkpoint-pi
{callPackage}:
callPackage ../build-support/pi-extension.nix {
  npmName = "checkpoint-pi";
  source = ./source.json;
  npmRoot = ./npm-deps;
  description = "Git-based checkpoint extension for pi-coding-agent - creates checkpoints at each turn for code state restoration";
}
