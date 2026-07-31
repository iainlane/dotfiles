# Rootful Podman quadlets, declared through `virtualisation.quadlet`.
#
# quadlet-nix is written against NixOS. `./podman.nix` supplies the podman
# options and the /etc/containers files it builds on; what remains here is the
# generator, and autostart.
{
  config,
  inputs,
  lib,
  ...
}: let
  quadletObjects = lib.concatMap lib.attrValues (
    with config.virtualisation.quadlet; [
      builds
      containers
      images
      kubes
      networks
      pods
      volumes
    ]
  );

  # Mirrors quadlet-nix's own reading of `autoStart`: a string names the target
  # directly, `true` means the usual one for a system service.
  wantedBy = object:
    if builtins.isString object._autoStart
    then [object._autoStart]
    else if object._autoStart
    then ["multi-user.target"]
    else [];
in {
  imports = [
    ./podman.nix
    inputs.quadlet-nix.nixosModules.quadlet
  ];

  config = lib.mkIf config.virtualisation.podman.enable {
    environment.etc = lib.mkMerge (
      [
        {
          # systemd runs generators from here at boot and on daemon-reload,
          # turning the files quadlet-nix writes to /etc/containers/systemd
          # into units.
          "systemd/system-generators/podman-system-generator".source = "${config.virtualisation.podman.package}/lib/systemd/system-generators/podman-system-generator";
        }
      ]
      # quadlet-nix expresses autostart as `wantedBy` on a `systemd.services`
      # entry per object, which NixOS renders as a drop-in over the unit the
      # generator produces. system-manager writes those entries as whole unit
      # files, and because /etc/systemd/system outranks /run/systemd/generator,
      # each one shadows the generated unit with a near-empty file that has no
      # ExecStart, which systemd refuses to load.
      #
      # Quadlet reads an [Install] section straight out of the quadlet file, so
      # autostart is expressed there and the shadowing units are left unwritten.
      ++ map (object: {
        "containers/systemd/${object.ref}".text = lib.mkForce (
          object._configText
          + lib.optionalString (wantedBy object != []) ''

            [Install]
            ${lib.concatMapStringsSep "\n" (target: "WantedBy=${target}") (wantedBy object)}
          ''
        );
      })
      quadletObjects
    );

    systemd.services = lib.mkMerge (map (object: {
        ${object._serviceName}.enable = false;
      })
      quadletObjects);
  };
}
