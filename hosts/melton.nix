{config, ...}: let
  inherit (config.dotfiles) features halls;
in {
  dotfiles.hosts.melton = {
    hostname = "melton.local";
    os = "darwin";
    arch = "aarch64";
    motd = halls.melton;
    features = [
      features.agentsview
      features.inference.ollama
      features.inference.librechat
      features.inference.acceleration.metal
      features.base
      features.development
      features.desktop
      features.nixbuild-builder
      features.home
    ];

    homeModule = {
      dotfiles = {
        agentsview.disabledAgents = ["warp"];
        git.signing.global.openpgp.key = "E352D5C51C5041D4";
        nixbuild.admin = true;
      };

      targets.darwin.defaults = {
        NSGlobalDomain.AppleShowAllExtensions = true;
      };
    };
  };
}
