{
  flake.profiles.containers.os.nixos = {
    homeManagerModule = {
      home.sessionVariables = {
        DOCKER_HOST = "unix://\${XDG_RUNTIME_DIR}/podman/podman.sock";
      };
    };

    nixosModule = {
      virtualisation.podman = {
        enable = true;
        dockerCompat = true;
        defaultNetwork.settings.dns_enabled = true;
      };
    };
  };
}
