{
  flake.profiles.unifi = {
    homeManagerModule = {
      config,
      hostConfig,
      lib,
      pkgs,
      ...
    }: let
      cfg = config.services.unifi;
      sources = lib.importJSON ./sources.json;
      platform =
        sources.platforms.${pkgs.stdenv.hostPlatform.system}
          or (throw "unifi: unsupported system ${pkgs.stdenv.hostPlatform.system}");
      imageRef = "docker.io/library/${sources.imageTag}";
      imagePath = import ./image.nix {
        inherit pkgs;
        inherit (platform) url hash;
        inherit (sources) version;
      };
      unifiContainer = import ./container.nix {
        inherit hostConfig pkgs cfg imagePath imageRef;
        serverVersion = sources.version;
      };
    in {
      imports = [./options.nix];

      config.services.podman = {
        enable = true;
        containers.unifi-os = unifiContainer;
      };
    };

    systemManagerModule = {
      lib,
      username,
      ...
    }: {
      config = {
        users.users.${username} = {
          autoSubUidGidRange = lib.mkDefault true;
          linger = lib.mkDefault true;
        };

        environment.etc = {
          # macvlan kernel module for device discovery
          "modules-load.d/unifi.conf".text = ''
            macvlan
          '';

          # Allow unprivileged users to send ICMP (needed for device discovery)
          "sysctl.d/99-unifi.conf".text = ''
            net.ipv4.ping_group_range=0 65534
          '';
        };
      };
    };
  };
}
