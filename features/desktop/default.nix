{config, ...}: let
  inherit (config.flake) features;
  children = features.desktop.provides;
in {
  imports = [
    ./chrome
    ./console
    ./cursor
    ./fonts
    ./ghostty
    ./gnome
    ./gpg-agent
    ./kitty
    ./plymouth
    ./secure-boot
    ./tailscale
    ./usbguard
    ./vm-host
    ./voxtype
    ./vscode
    ./wine
    ./zed-editor
  ];

  flake.features.desktop = {
    includes = with children; [
      features.ai
      features.ai.provides.claude-desktop
      ghostty
      kitty
      voxtype
      zed-editor
      vscode
      cursor
      chrome
      fonts
      gpg-agent
    ];

    os = {
      nixos.includes = with children; [
        gnome
        vm-host
        secure-boot
        plymouth
        console
        tailscale
        usbguard
      ];

      darwin.includes = [children.wine];
    };

    homeManager = ./home-manager.nix;
    darwin = ./darwin.nix;
    nixos = ./nixos.nix;
  };
}
