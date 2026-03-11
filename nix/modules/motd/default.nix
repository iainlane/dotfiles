_: let
  homeManagerModule = {
    hostConfig,
    lib,
    ...
  }:
    lib.mkIf (hostConfig ? motd) {
      programs.zsh.loginExtra = ''
        printf '\n%s\n' ${lib.escapeShellArg hostConfig.motd}
      '';
    };
in {
  flake.modules.motd = {
    homeManagerModules = [homeManagerModule];
  };
}
