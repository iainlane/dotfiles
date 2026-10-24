{
  config,
  featureResolver,
  ...
}: let
  inherit (config.dotfiles) features;
  children = features.base;
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

  dotfiles.features.base = {
    includes =
      (with children; [
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
      ])
      ++ [
        (featureResolver.when featureResolver.isNixos (with children; [restic openssh]))
        (featureResolver.when featureResolver.isGenericLinux [
          {
            includes = [children.system-manager-shell];
            homeManager = ./home-manager-generic-linux.nix;
          }
        ])
        (featureResolver.when featureResolver.isDarwin [
          {
            includes = with children; [homebrew macos-defaults];
            homeManager = ./home-manager-darwin.nix;
          }
        ])
        (featureResolver.when featureResolver.isLinux [{homeManager = ./home-manager-linux.nix;}])
      ];

    homeManager = ./home-manager.nix;
  };
}
