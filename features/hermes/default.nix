{config, ...}: let
  inherit (config.flake) features;
  children = features.hermes.provides;
  defaultModels = (import ../ai/models.nix).defaults;
in {
  imports = [
    ./agents
    ./agentsview
    ./backup
    ./dashboard
    ./embeddings
    ./homeassistant
    ./identity
    ./inbox
    ./matrix
    ./mcp
    ./signal
    ./soul
    ./webhook
  ];

  flake.features.hermes = {
    # Each platform adds its rendered secrets to `environmentFiles`, and
    # `builders.nix` concatenates those files into the agent's `.env` in the
    # order that they resolve here. Two platforms that define the same variable
    # therefore depend on this order.
    includes = [features.containers] ++ (with children; [dashboard signal matrix homeassistant mcp backup soul agents embeddings]);

    systemManager = {
      config,
      inputs,
      lib,
      pkgs,
      ...
    }: {
      imports = [
        ./options.nix
        ./core.nix
        ./models.nix
        ./terminal.nix
        ./browser.nix
        ./profile-picture.nix
        ./secret-env.nix
        ./context-engine.nix
      ];

      config = {
        # The image builder, the container template and the state volume names.
        # Several modules here build on them. Importing once and passing the
        # result as a module argument means the image is constructed once per
        # evaluation.
        _module.args.hermesBuilders = import ./builders.nix {inherit config inputs lib pkgs;};

        dotfiles.hermes.settings = {
          model.default = lib.mkDefault defaultModels.openai;
          fallback_providers = lib.mkDefault [
            {
              provider = "openrouter";
              model = "openai/${defaultModels.openai}";
            }
          ];
        };

        # Reserved for the agent, the dashboard and signal-cli, which share
        # state volumes and so map their ids from one range to see the same
        # owner on a file. The range starts above the window NixOS allocates
        # subordinate ids from, so NixOS will not hand out ids inside it.
        virtualisation.containers.idRanges.hermes.start = 1900644000;
      };
    };
  };
}
