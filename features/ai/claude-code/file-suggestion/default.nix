# Claude Code `fileSuggestion` command: replaces the built-in `@` picker with
# `fd | fzf --filter`. Wired into `dotfiles.claudeCode.managedSettings` via
# `lib.getExe`. See `file-suggestion.sh` for the selection logic.
{
  writeShellApplication,
  coreutils,
  fd,
  fzf,
  gawk,
  gnused,
}:
writeShellApplication {
  name = "claude-file-suggestion";
  runtimeInputs = [
    fd
    fzf
    coreutils
    gnused
    gawk
  ];
  text = builtins.readFile ./file-suggestion.sh;
}
