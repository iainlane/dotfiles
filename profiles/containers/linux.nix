{
  flake.profiles.containers.os.linux.systemManagerModule = _: {
    config,
    lib,
    pkgs,
    ...
  }: let
    cfg = config.virtualisation.containers.subordinatePool;

    userRanges =
      lib.concatMap (
        user:
          map (range: {
            inherit (user) name;
            inherit (range) count;
            start = range.startUid;
          })
          user.subUidRanges
          ++ map (range: {
            inherit (user) name;
            inherit (range) count;
            start = range.startGid;
          })
          user.subGidRanges
      )
      (lib.attrValues config.users.users);

    overlappingRanges =
      lib.filter
      (range: range.start < cfg.start + cfg.count && cfg.start < range.start + range.count)
      userRanges;

    subordinateFile = startField: rangesField:
      lib.concatLines (
        lib.concatMap (
          user:
            map (range: "${user.name}:${toString range.${startField}}:${toString range.count}")
            user.${rangesField}
        )
        (lib.attrValues config.users.users)
        ++ ["containers:${toString cfg.start}:${toString cfg.count}"]
      );
  in {
    imports = [
      ./edge-proxy.nix
      ./quadlet.nix
    ];

    options.virtualisation.containers.subordinatePool = {
      start = lib.mkOption {
        type = lib.types.int;
        default = 1000000;
        description = ''
          First host id of the pool podman draws per-container user namespace
          ranges from, written to /etc/subuid and /etc/subgid as the
          `containers` entry that `--userns=auto` requires.
        '';
      };

      count = lib.mkOption {
        type = lib.types.int;
        default = 65536000;
        description = "Size of that pool, in ids.";
      };
    };

    config = {
      assertions = [
        {
          assertion = overlappingRanges == [];
          message = ''
            virtualisation.containers.subordinatePool covers ${toString cfg.start}
            to ${toString (cfg.start + cfg.count - 1)}, which podman hands out to
            containers. It overlaps subordinate ranges belonging to:
            ${lib.concatMapStringsSep ", " (range: "${range.name} (${toString range.start}+${toString range.count})") overlappingRanges}.
          '';
        }
      ];

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

        "subuid" = {
          replaceExisting = true;
          text = subordinateFile "startUid" "subUidRanges";
        };

        "subgid" = {
          replaceExisting = true;
          text = subordinateFile "startGid" "subGidRanges";
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
