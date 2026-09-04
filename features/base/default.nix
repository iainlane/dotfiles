{config, ...}: let
  inherit (config.flake) features;
  children = features.base.provides;
in {
  imports = [
    ./catppuccin
    ./cli-tools
    ./gh
    ./homebrew
    ./macos-defaults
    ./motd
    ./neovim
    ./nix
    ./openssh
    ./restic
    ./scripts
    ./ssh
    ./starship
    ./sudo
    ./system-manager-shell
    ./zsh
  ];

  flake.features.base = {
    includes = with children; [
      catppuccin
      gh
      features.git
      motd
      scripts
      ssh
      zsh
      neovim
      starship
      cli-tools
      nix
      sudo
    ];

    os = {
      nixos.includes = with children; [restic openssh];

      "generic-linux" = {
        includes = [children.system-manager-shell];
        homeManager = ./home-manager-generic-linux.nix;
      };

      darwin = {
        includes = with children; [homebrew macos-defaults];
        homeManager = ./home-manager-darwin.nix;
      };
    };

    kernel.linux.homeManager = ./home-manager-linux.nix;

    homeManager = ./home-manager.nix;
  };
}
