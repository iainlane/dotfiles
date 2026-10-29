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
      sops.secrets = {
        teamclaude-anthropic-api-key = {
          sopsFile = inputs.secrets + "/melton/user-teamclaude.yaml";
          key = "anthropic_api_key";
        };

        librechat-anthropic-api-key = {
          sopsFile = inputs.secrets + "/melton/user-librechat.yaml";
          key = "anthropic_api_key";
        };

        openrouter-api-key = {
          sopsFile = inputs.secrets + "/melton/user-librechat.yaml";
          key = "openrouter_api_key";
        };
      };

      dotfiles = {
        ai.openrouterApiKeyFile = config.sops.secrets.openrouter-api-key.path;
        agentsview.disabledAgents = ["warp"];
        claudeCode.teamclaude.apiKeyAccounts.anthropic.apiKeyFile = config.sops.secrets.teamclaude-anthropic-api-key.path;
        inference.librechat.anthropicKeyFile = config.sops.secrets.librechat-anthropic-api-key.path;
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
