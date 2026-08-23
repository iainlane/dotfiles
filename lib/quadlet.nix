{lib}: let
  inherit (lib) mkOption types;

  mountNameType = types.strMatching "[^/:]+";
  absolutePathType = types.strMatching "/[^:]*";
  hostPathType = types.coercedTo (types.either types.path types.package) (value: "${value}") absolutePathType;

  sourceType = types.attrTag {
    quadletVolume = mkOption {
      type = mountNameType;
      description = "Name of a volume declared in `virtualisation.quadlet.volumes`.";
    };

    podmanVolume = mkOption {
      type = mountNameType;
      description = "Name of a Podman-managed volume.";
    };

    bind = mkOption {
      type = hostPathType;
      description = "Absolute host path to bind mount.";
    };
  };

  mountType = types.submodule {
    options = {
      source = mkOption {
        type = sourceType;
        description = "Host-side source of the mount.";
      };

      target = mkOption {
        type = absolutePathType;
        description = "Absolute path at which to mount the source in the container.";
      };

      readOnly = mkOption {
        type = types.bool;
        default = false;
        description = "Whether the container can only read the mount.";
      };

      ownership = mkOption {
        type = types.nullOr (types.enum ["idmap" "chown"]);
        default = null;
        description = ''
          How Podman adjusts ownership for the container. `idmap` maps the
          source through the container's user namespace. `chown` changes the
          source ownership before the container starts.
        '';
      };
    };
  };

  checkedMounts = values:
    (lib.evalModules {
      modules = [
        {
          options.mounts = mkOption {type = types.listOf mountType;};
          config.mounts = values;
        }
      ];
    }).config.mounts;

  renderSource = source:
    if source ? quadletVolume
    then "${source.quadletVolume}.volume"
    else source.podmanVolume or source.bind;

  renderMount = checked: let
    options =
      lib.optional (checked.ownership == "idmap") "idmap"
      ++ lib.optional (checked.ownership == "chown") "U"
      ++ lib.optional checked.readOnly "ro";
  in
    "${renderSource checked.source}:${checked.target}"
    + lib.optionalString (options != []) ":${lib.concatStringsSep "," options}";

  mounts = values: map renderMount (checkedMounts values);

  mount = value: lib.head (mounts [value]);

  isAutoUserns = userns:
    userns == "auto" || (userns != null && lib.hasPrefix "auto:" userns);

  isNamedVolume = value: let
    parts = lib.splitString ":" value;
  in
    lib.length parts >= 2 && !lib.hasInfix "/" (lib.head parts);

  hasIdmap = value: let
    options = lib.concatMap (lib.splitString ",") (lib.drop 2 (lib.splitString ":" value));
  in
    lib.any (option: option == "idmap" || lib.hasPrefix "idmap=" option) options;
in {
  inherit mount mounts mountType;

  autoUsernsVolumesWithoutIdmap = containers:
    lib.concatLists (
      lib.mapAttrsToList (
        container: value: let
          containerConfig = value.containerConfig or {};
        in
          if isAutoUserns (containerConfig.userns or null)
          then
            map
            (volume: {
              inherit container;
              mount = volume;
            })
            (lib.filter (volume: isNamedVolume volume && !hasIdmap volume) (containerConfig.volumes or []))
          else []
      )
      containers
    );
}
