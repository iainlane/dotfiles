{
  flake.profiles.containers.os.linux.systemManagerModule = _: {pkgs, ...}: {
    imports = [
      ./edge-proxy.nix
      ./quadlet.nix
    ];

    config = {
      virtualisation.podman = {
        enable = true;

        # Every build tags its image with the store hash, so an image that a
        # newer build has superseded keeps its tag and stays out of reach of a
        # plain prune. `--all` collects those, and the age floor leaves images
        # belonging to units that have not started yet.
        autoPrune = {
          enable = true;
          dates = "weekly";
          flags = ["--all" "--filter" "until=168h"];
        };
      };

      environment.etc = {
        # Create /etc/containers/nodocker to indicate Docker isn't installed. Some
        # container tools check for this to avoid trying to use the Docker socket.
        "containers/nodocker".text = "";
      };

      # Rootless podman needs newuidmap/newgidmap with setuid privileges.
      # system-manager does not expose security.wrappers, so install helpers
      # into /usr/local/libexec/podman at boot.
      systemd.services.install-rootless-uidmap-wrappers = {
        description = "Install setuid uidmap helpers for rootless containers";
        wantedBy = ["sysinit.target"];
        after = ["local-fs.target"];
        before = ["systemd-user-sessions.service"];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          install -d -m 0755 /usr/local/libexec/podman
          install -m 4755 -o root -g root ${pkgs.shadow}/bin/newuidmap /usr/local/libexec/podman/newuidmap
          install -m 4755 -o root -g root ${pkgs.shadow}/bin/newgidmap /usr/local/libexec/podman/newgidmap
        '';
      };
    };
  };
}
