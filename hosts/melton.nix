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
      features.ai.rea
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
      config,
      inputs,
      ...
    }: {
      sops.secrets.anthropic-api-key = {
        sopsFile = inputs.secrets + "/melton/user-anthropic.yaml";
        key = "anthropic_api_key";
      };

      sops.secrets.openrouter-api-key = {
        sopsFile = inputs.secrets + "/melton/user-librechat.yaml";
        key = "openrouter_api_key";
      };

      dotfiles = {
        ai.anthropicApiKeyFile = config.sops.secrets.anthropic-api-key.path;
        ai.openrouterApiKeyFile = config.sops.secrets.openrouter-api-key.path;
        agentsview.disabledAgents = ["warp"];
        inference.librechat.excludeBundles = ["rea"];
        git.signing.global.openpgp.key = "E352D5C51C5041D4";
        nixbuild.admin = true;
      };

      targets.darwin.defaults = {
        NSGlobalDomain.AppleShowAllExtensions = true;
      };
    };
  };
}
