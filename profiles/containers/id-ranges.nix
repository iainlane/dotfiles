# Subordinate id ranges, reserved by name.
#
# This declares the ranges and checks that no two of them cover the same id.
# Writing them to /etc/subuid and /etc/subgid is left to the module for the
# platform, because NixOS writes both files itself.
{
  config,
  lib,
  ...
}: let
  inherit (config.virtualisation.containers) idRanges;

  ranges =
    lib.mapAttrsToList (name: range: {
      inherit name;
      inherit (range) start size;
    })
    idRanges;

  overlap = a: b: a.start < b.start + b.size && b.start < a.start + a.size;

  describe = range: "${range.name} (${toString range.start}+${toString range.size})";

  conflicts = lib.concatLists (
    lib.imap0 (
      index: range:
        map (other: "${describe range} and ${describe other}")
        (lib.filter (overlap range) (lib.drop (index + 1) ranges))
    )
    ranges
  );
in {
  options.virtualisation.containers.idRanges = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule (range: {
      options = {
        start = lib.mkOption {
          type = lib.types.ints.unsigned;
          example = 1900644000;
          description = "First host id of the range, for both uids and gids.";
        };

        size = lib.mkOption {
          type = lib.types.ints.positive;
          default = 65536;
          description = "How many ids the range covers.";
        };

        uidMaps = lib.mkOption {
          type = with lib.types; listOf str;
          readOnly = true;
          description = ''
            A container's `uidMaps`, laying the range over the namespace
            from id 0 up. The ids are the host's own, which is how podman
            reads a map it is given as root; a rootless container reads the
            same field as an id in its intermediate namespace instead, so
            these belong only to containers a host runs as root.

            `--uidmap` conflicts with `--userns` and `--subuidname`, so a
            container takes these or names a namespace, never both.
          '';
        };

        gidMaps = lib.mkOption {
          type = with lib.types; listOf str;
          readOnly = true;
          description = "The same, for gids.";
        };
      };

      config = let
        span = "0:${toString range.config.start}:${toString range.config.size}";
      in {
        uidMaps = [span];
        gidMaps = [span];
      };
    }));
    default = {};
    example = lib.literalExpression ''{ hermes.start = 1900644000; }'';
    description = ''
      Every subordinate id range on this host, by name. A range covers uids
      and gids alike, since a container maps both.

      A name records who holds the range. `containers` is the one podman
      looks up when `--userns=auto` draws a range; a login name grants that
      user ids to map rootless; any other name reserves ids for containers a
      host runs as root, which map them directly and so need no entry to
      claim.

      Containers that share a volume take their maps from the same range, so
      a file one writes is one the other can read; `--userns=auto` draws a
      fresh range per container and cannot give them that.

      Ranges are asserted to be distinct, so a reservation made here cannot
      collide with one made anywhere else.
    '';
  };

  config.assertions = [
    {
      assertion = conflicts == [];
      message = ''
        Subordinate id ranges overlap, so one id would have two owners:
        ${lib.concatStringsSep "; " conflicts}.
      '';
    }
  ];
}
