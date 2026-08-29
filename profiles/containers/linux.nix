{
  flake.profiles.containers.os.linux.systemManagerModule = _: {
    config,
    lib,
    pkgs,
    username,
    ...
  }: let
    inherit (config.virtualisation.containers) idRanges;

    # `newuidmap` reads these to decide what a user may map rootless, and
    # nothing else on the host writes them.
    subordinateFile = lib.concatLines (
      lib.mapAttrsToList
      (name: range: "${name}:${toString range.start}:${toString range.size}")
      idRanges
    );

    usersWithRanges = lib.attrNames (
      lib.filterAttrs
      (_: user: user.subUidRanges != [] || user.subGidRanges != [])
      config.users.users
    );
  in {
    imports = [
      ./edge-proxy.nix
      ./id-ranges.nix
      ./identity-provider.nix
      ./quadlet.nix
    ];

    config = {
      assertions = [
        {
          assertion = usersWithRanges == [];
          message = ''
            /etc/subuid and /etc/subgid are written from
            virtualisation.containers.idRanges, so the subordinate ids set on
            ${lib.concatStringsSep ", " usersWithRanges} through users.users
            would reach neither file. Declare them as idRanges instead.
          '';
        }
      ];

      virtualisation.containers.idRanges = {
        # The name `--userns=auto` looks up when it draws a range for a
        # container that asks for one of its own.
        containers = {
          start = lib.mkDefault 1000000;
          size = lib.mkDefault 65536000;
        };

        # Rootless container storage on disk is already owned inside this
        # range, so it has to keep matching what the distribution allocated.
        ${username}.start = lib.mkDefault 165536;
      };

      virtualisation.podman = {
        enable = true;

        # Every build tags its image with the store hash, so an image that a
        # newer build has superseded keeps its tag and stays out of reach of
        # a plain prune. `--all` collects those. The `until` filter compares
        # creation dates, and Nix dates its images at the Unix epoch, so only
        # registry images pulled within the last week are exempt.
        autoPrune = {
          enable = true;
          dates = "weekly";
          flags = ["--all" "--filter" "until=168h"];
        };
      };

      # Only a running container protects a Nix-built image from the prune.
      # Wait for the containers, so a timer run replayed just after boot does
      # not delete the images the image units have just pulled.
      systemd.services.podman-prune.after = ["system-manager.target"];

      environment.etc = {
        # Create /etc/containers/nodocker to indicate Docker isn't installed. Some
        # container tools check for this to avoid trying to use the Docker socket.
        "containers/nodocker".text = "";

        # `newuidmap` and `newgidmap` are setuid, and open these without
        # following symlinks, so they have to be real files.
        "subuid" = {
          replaceExisting = true;
          mode = "0644";
          text = subordinateFile;
        };

        "subgid" = {
          replaceExisting = true;
          mode = "0644";
          text = subordinateFile;
        };
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
