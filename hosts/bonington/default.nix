{config, ...}: let
  inherit (config.flake) features halls;
in {
  flake.hosts.bonington = {
    os = "nixos";
    arch = "x86_64";
    channel = "stable";
    stateVersion = "25.05";
    motd = halls.bonington;
    features = [
      features.agentsview
      features.base
      features.nixbuild-builder
      features.desktop
      features.development
      features.cloud
      features.containers
      features.inference
      features.work
      features.work.provides.claude-managed-settings
    ];

    systemModule = {
      imports = [
        ./hardware.nix
        ./disks.nix
      ];

      dotfiles.usbguard.staticRules."10-scarlett.conf" = ''
        allow id 1235:8219 serial "S2AR8Q3350C05D"
      '';
    };

    homeModule = {
      dotfiles.git.signing.global.ssh.key = "~/.ssh/id_ed25519";

      programs.git.settings.user.email = "iain.lane@chainguard.dev";
    };
  };
}
