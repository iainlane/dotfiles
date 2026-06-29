# Build outputs for the cupboard publish workflow.
#
# `flake.cupboardOutputs` enumerates everything that workflow caches: one entry
# per package (for every system) and one per host or home closure. The workflow
# evaluates it and fans out a build job per entry, so this list lives here with
# the flake data rather than as shell and jq in the workflow. Each entry carries
# enough to run and route its job:
#
#   - os/remote: the runner, and whether it offloads to nixbuild.net (Linux) or
#     builds natively (Darwin).
#   - kind: `package` (built strictly) or `closure` (best-effort).
#   - attr: the flake installable to build.
#   - rootSuffix: appended to the per-event prefix to form the retention root.
{
  config,
  lib,
  ...
}: let
  inherit (config.flake) packages hosts homeConfigurations;

  systems = lib.attrNames packages;

  baseFor = kind: system: {
    inherit system kind;
    os =
      if lib.hasSuffix "-darwin" system
      then "macos-latest"
      else "ubuntu-latest";
    remote = !lib.hasSuffix "-darwin" system;
  };

  # Installer images are exposed for every system but embed a host closure, so
  # they are not worth caching.
  isInstaller = name:
    builtins.match ".*-(iso|iso-contents|netboot-installer)" name != null;

  packageEntries =
    lib.concatMap (
      system:
        map (name:
          baseFor "package" system
          // {
            attr = ".#packages.${system}.${name}";
            rootSuffix = "${system}/${name}";
          })
        (lib.filter (name: !isInstaller name) (lib.attrNames packages.${system}))
    )
    systems;

  # The system closure: a NixOS toplevel or a nix-darwin system. The
  # system-manager Linux hosts have neither, so they contribute only a home
  # closure below.
  systemClosure = name: host:
    if host.os == "nixos"
    then [
      (baseFor "closure" host.system
        // {
          attr = ".#nixosConfigurations.${name}.config.system.build.toplevel";
          rootSuffix = "${host.system}/nixos-${name}";
        })
    ]
    else if host.os == "darwin"
    then [
      (baseFor "closure" host.system
        // {
          attr = ".#darwinConfigurations.${name}.system";
          rootSuffix = "${host.system}/darwin-${name}";
        })
    ]
    else [];

  homeEntry = homeName: let
    hostname = lib.last (lib.splitString "@" homeName);
    inherit (hosts.${hostname}) system;
  in
    baseFor "closure" system
    // {
      attr = ''.#homeConfigurations."${homeName}".activationPackage'';
      rootSuffix = "${system}/home-${hostname}";
    };

  closureEntries =
    lib.concatLists (lib.mapAttrsToList systemClosure hosts)
    ++ map homeEntry (lib.attrNames homeConfigurations);
in {
  flake.cupboardOutputs = packageEntries ++ closureEntries;
}
