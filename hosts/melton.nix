{config, ...}: let
  inherit (config.flake) features halls;
in {
  flake.hosts.melton = {
    hostname = "melton.local";
    os = "darwin";
    arch = "aarch64";
    motd = halls.melton;
    features = [
      features.agentsview
      features.agentsview.provides.embeddings.provides.local
      features.base
      features.development
      features.desktop
      features.nixbuild-builder
      features.home
    ];

    homeModule = {
      dotfiles = {
        git.signing.global.openpgp.key = "E352D5C51C5041D4";
        nixbuild.admin = true;
      };

      targets.darwin.defaults = {
        NSGlobalDomain.AppleShowAllExtensions = true;
      };
    };
  };
}
