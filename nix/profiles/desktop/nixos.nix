{config, ...}: let
  inherit (config.flake.modules) gnome;
  vmHost = config.flake.modules."vm-host";
in {
  flake.profiles.desktop.os.nixos = {
    modules = [gnome vmHost];

    nixosModule = {pkgs, ...}: {
      fonts.packages = with pkgs; [
        cascadia-code
        monaspace
        nerd-fonts.caskaydia-cove
        nerd-fonts.caskaydia-mono
        nerd-fonts.fira-code
        nerd-fonts.hack
        nerd-fonts.monaspace
        powerline-fonts
        roboto
      ];
    };
  };
}
