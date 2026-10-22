{
  config,
  lib,
  ...
}: {
  programs.zsh = {
    enableGlobalCompInit = false;
    interactiveShellInit = lib.mkAfter (lib.optionalString config.programs.zsh.enableCompletion (builtins.readFile ./global-compinit.zsh));
  };
}
