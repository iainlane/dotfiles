{config, ...}: let
  defaultModels = import ../../features/ai/models.nix;
in {
  flake.features.hermes = {
    includes = [config.flake.features.containers];

    systemManager = {lib, ...}: {
      imports = [
        ./options.nix
        ./core.nix
        ./models.nix
        ./terminal.nix
        ./browser.nix
        ./dashboard.nix
        ./signal.nix
        ./matrix.nix
        ./profile-picture.nix
        ./homeassistant.nix
        ./secret-env.nix
        ./mcp.nix
        ./context-engine.nix
        ./backup.nix
      ];

      config = {
        # Giving a host the feature is enough to run the agent.
        services.hermes-agent = {
          enable = lib.mkDefault true;
          settings = {
            model.default = lib.mkDefault defaultModels.openai;
            fallback_providers = lib.mkDefault [
              {
                provider = "openrouter";
                model = "openai/${defaultModels.openai}";
              }
            ];
          };
        };

        # Reserved for the agent, the dashboard and signal-cli, which share
        # state volumes and so map their ids from one range to see the same
        # owner on a file. It sits above the window NixOS allocates
        # subordinate ids from, so the reservation holds there too.
        virtualisation.containers.idRanges.hermes.start = 1900644000;
      };
    };
  };
}
