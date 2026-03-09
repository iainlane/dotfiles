{
  flake.profiles.containers.os.nixos = {
    homeManagerModule = import ./linux-home.nix;

    nixosModule = {
      virtualisation.podman = {
        enable = true;
        dockerCompat = true;
        defaultNetwork.settings.dns_enabled = true;
      };
    };
  };
}
