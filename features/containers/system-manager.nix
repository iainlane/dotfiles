{
  config,
  lib,
  pkgs,
  username,
  ...
}: let
  inherit (config.virtualisation.containers) idRanges;

  # `newuidmap` reads /etc/subuid and /etc/subgid to decide which ids a user
  # may map rootless. Nothing else on the host writes them.
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

  # Nix builds an image's OCI config with an epoch creation time, for
  # reproducibility (see `lib/container-image.nix`), so the `until=168h`
  # prune filter below can never treat one as recent no matter when it
  # was actually pulled into local storage. That leaves the prune's
  # other check, being referenced by an existing container, as the only
  # thing keeping a Nix-built image alive. A container that only runs
  # briefly on a timer, rather than staying up, has no such reference
  # between runs, so a prune sweeping through in that window removes an
  # image the current generation still wants.
  #
  # Rather than track which containers stay running, make every
  # Nix-built image unit pull its image again whenever something
  # depends on it. `RemainAfterExit = false` makes the unit go inactive
  # once the pull finishes, so `Requires=`/`After=` on a dependent unit
  # reruns it on every start. The pull re-imports the same tag from the
  # already-built store path, so repeating it costs a local copy, not a
  # network fetch.
  nixBuiltImageOverrides =
    lib.mapAttrs' (
      name: _image:
        lib.nameValuePair "${name}-image" {
          serviceConfig.RemainAfterExit = lib.mkForce false;
        }
    ) (lib.filterAttrs (_: image: lib.hasPrefix "docker-archive:" image.imageConfig.image)
      config.virtualisation.quadlet.images);
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
      # The name podman looks up in /etc/subuid when `--userns=auto` draws a
      # range for a container.
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

      # The helper podman runs for rootless networking. It goes on podman's own
      # PATH because podman is what looks for it; the podman package already
      # includes its other helpers, `fuse-overlayfs` among them.
      extraPackages = [pkgs.slirp4netns];

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

    systemd.services =
      {
        # Only a running container protects a Nix-built image from the
        # prune. Wait for the containers, so a timer run replayed just
        # after boot does not delete the images the image units have
        # just pulled.
        podman-prune.after = ["system-manager.target"];

        # Rootless podman maps ids through setuid newuidmap and newgidmap.
        # /usr/local/libexec/podman is the first of podman's compiled-in
        # `helper_binaries_dir` entries, so setuid copies installed there are
        # the ones it finds.
        install-rootless-uidmap-wrappers = {
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
      }
      // nixBuiltImageOverrides;

    environment.etc = {
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
  };
}
