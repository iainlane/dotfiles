# Codex spawns a separate `codex-code-mode-host` binary to run shell and
# file-edit commands, and looks for it next to its own executable.
# llm-agents.nix only builds the `codex-cli` package, so the host binary is
# missing from the store path and no shell or file-edit command can start.
# Build it as well so it is installed alongside `codex` in `bin/`. Drop this
# once https://github.com/numtide/llm-agents.nix/pull/6631 lands and the
# input is bumped past it.
{
  inputs,
  system,
}:
inputs.llm-agents.packages.${system}.codex.overrideAttrs (old: {
  cargoBuildFlags = old.cargoBuildFlags ++ ["--package" "codex-code-mode-host"];
})
