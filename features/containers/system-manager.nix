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

  # Nix-built images have an epoch creation time for reproducibility (see
  # `lib/container-image.nix`), so `until=168h` does not protect recently
  # imported images from pruning. A timer-driven container can leave its
  # image unreferenced between runs, so pruning can remove an image required
  # by the current generation.
  #
  # `RemainAfterExit = false` makes image units inactive after each import.
  # A dependent unit's `Requires=`/`After=` then starts the image unit on
  # every run, so it restores an image removed by pruning.
  #
  # Importing a docker-archive decompresses and hashes every layer and writes
  # the layers to disk. On large images this takes tens of seconds of CPU.
  # Skip the import while the tag exists locally so crashing containers do
  # not repeat that work on every restart.
  imageAbsent = pkgs.writeShellScript "podman-image-absent" (builtins.readFile ../../lib/podman-image-absent.bash);

  nixBuiltImageOverrides =
    lib.mapAttrs' (
      name: image:
        lib.nameValuePair "${name}-image" {
          path = [config.virtualisation.podman.package];
          serviceConfig = {
            RemainAfterExit = lib.mkForce false;
            ExecCondition = "${imageAbsent} ${lib.escapeShellArg image.imageConfig.tag}";
          };
        }
    ) (lib.filterAttrs (
        _: image:
          lib.hasPrefix "docker-archive:" image.imageConfig.image && image.imageConfig.tag != null
      )
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
        # after boot does not delete the images that the image units have
        # just pulled.
        podman-prune.after = ["system-manager.target"];

        # Rootless podman maps ids through setuid newuidmap and newgidmap.
        # /usr/local/libexec/podman is the first of podman's compiled-in
        # `helper_binaries_dir` entries, so setuid copies installed there are
        # the ones that podman finds.
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
