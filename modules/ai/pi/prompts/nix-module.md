---
description: Work on a Nix, Home Manager, or flake module change
argument-hint: "<task>"
model: claude-sonnet-4-6
thinking: high
---

# Work on a Nix module

Help with this Nix module or flake task: $@

Read the surrounding modules before editing. Preserve the existing option
structure, naming, and formatting conventions. Prefer small, composable Nix
expressions over ad-hoc shell where possible.

After changing files, run the narrowest relevant formatter or evaluation first,
then the broader project check if appropriate. For this dotfiles repository,
prefer `nix fmt` for formatting and use `nix flake check` only when the scope
justifies the cost.
