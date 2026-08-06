{
  flake.profiles.hermes = {
    requires = [
      {
        profile = "containers";
        os = ["linux"];
      }
    ];

    os.linux.homeManagerModule = args: {lib, ...}: {
      imports = [
        ./options.nix
        ./core.nix
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

      # The host's per-profile settings arrive as `args`; default the service on
      # so opting into the profile is enough to get the agent.
      config.services.hermes-agent =
        {
          enable = lib.mkDefault true;
        }
        // args;
    };

    os.linux.systemManagerModule = {
      lib,
      username,
      ...
    }: {
      config = {
        users.users.${username}.linger = lib.mkDefault true;

        # Reserved for the agent, the dashboard and signal-cli, which share
        # state volumes and so map their ids from one range to see the same
        # owner on a file. It sits above the window NixOS allocates
        # subordinate ids from, so the reservation holds there too.
        virtualisation.containers.idRanges.hermes.start = 1900644000;
      };
    };
  };
}
