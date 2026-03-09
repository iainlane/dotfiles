{
  flake.profiles.containers.os.linux.homeManagerModule = import ./linux-home.nix;

  flake.profiles.containers.os.linux.systemManagerModule = {pkgs, ...}: {
    config = {
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
