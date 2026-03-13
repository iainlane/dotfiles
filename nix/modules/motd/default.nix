_: let
  homeManagerModule = {
    # config,
    hostConfig,
    lib,
    ...
  }:
    lib.mkIf (hostConfig ? motd) {
      home.file.".motd".text = hostConfig.motd;

      # too annoying, need to find a better way to present this
      # programs.zsh.loginExtra = ''
      #   echo
      #   cat -pP ${config.home.homeDirectory}/.motd
      # '';
    };
in {
  flake.modules.motd = {
    homeManagerModules = [homeManagerModule];
  };
}
