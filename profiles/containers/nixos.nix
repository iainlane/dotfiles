{config, ...}: {
  flake.profiles.containers.os.nixos = {
    inherit (config.flake.profiles.containers.os.linux) homeManagerModule;

    nixosModule = {
      virtualisation.podman = {
        enable = true;
        dockerCompat = true;
        defaultNetwork.settings.dns_enabled = true;
      };
    };
  };
}
