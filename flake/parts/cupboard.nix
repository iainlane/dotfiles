# Build outputs for the cupboard publish workflow.
#
# `flake.cupboardOutputs` enumerates the configured host and home closures. The
# workflow evaluates their derivation graphs, so packages are selected by the
# configurations that use them rather than by the flake's package export
# matrix. Each entry carries enough to plan, run and route its job:
#
#   - os/remote: the runner, and whether it offloads to nixbuild.net (Linux) or
#     builds natively (Darwin).
#   - bestEffort: true because closures can need resources CI cannot reach (a
#     token-gated fixed-output derivation such as the Falcon sensor).
#   - attr: the flake installable to build.
#   - rootDrvPath: the derivation graph root used to plan shared work.
#   - rootSuffix: appended to the per-event prefix to form the retention root.
{
  config,
  lib,
  ...
}: let
  inherit (config.flake) hosts homeConfigurations;

  baseFor = system: {
    inherit system;
    bestEffort = true;
    os =
      if lib.hasSuffix "-darwin" system
      then "macos-latest"
      else "ubuntu-latest";
    remote = !lib.hasSuffix "-darwin" system;
  };

  # The system closure: a NixOS toplevel or a nix-darwin system. The
  # system-manager Linux hosts have neither, so they contribute only a home
  # closure below.
  systemClosure = name: host:
    if host.os == "nixos"
    then [
      (let
        toplevel = config.flake.nixosConfigurations.${name}.config.system.build.toplevel;
      in
        baseFor host.system
        // {
          attr = ".#nixosConfigurations.${name}.config.system.build.toplevel";
          rootDrvPath = toplevel.drvPath;
          rootSuffix = "${host.system}/nixos-${name}";
        })
    ]
    else if host.os == "darwin"
    then [
      (let
        system = config.flake.darwinConfigurations.${name}.system;
      in
        baseFor host.system
        // {
          attr = ".#darwinConfigurations.${name}.system";
          rootDrvPath = system.drvPath;
          rootSuffix = "${host.system}/darwin-${name}";
        })
    ]
    else [];

  homeEntry = homeName: let
    hostname = lib.last (lib.splitString "@" homeName);
    inherit (hosts.${hostname}) system;
    activationPackage = homeConfigurations.${homeName}.activationPackage;
  in
    baseFor system
    // {
      attr = ''.#homeConfigurations."${homeName}".activationPackage'';
      rootDrvPath = activationPackage.drvPath;
      rootSuffix = "${system}/home-${hostname}";
    };

  closureEntries =
    lib.concatLists (lib.mapAttrsToList systemClosure hosts)
    ++ map homeEntry (lib.attrNames homeConfigurations);
in {
  flake.cupboardOutputs = closureEntries;
}
