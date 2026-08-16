# Build outputs for the cupboard publish workflow.
#
# `flake.cupboardOutputs` is the publication manifest consumed by the workflow.
# Each entry below targets a deploy-rs profile. A system profile contains the
# NixOS, nix-darwin or system-manager closure for one host. A home profile
# contains its Home Manager generation. Both profile types include the
# activation files that deploy-rs copies to the host.
#
# The workflow evaluates each profile's derivation graph, so packages are
# selected by the configurations that use them rather than by the flake's
# package export matrix. Each entry carries enough to plan, run and route its
# job:
#
#   - os/remote: the runner, and whether it offloads to nixbuild.net (Linux) or
#     builds natively (Darwin).
#   - bestEffort: true because closures can need resources CI cannot reach (a
#     token-gated fixed-output derivation such as the Falcon sensor).
#   - cohort: the system, so every target for one system builds in a single
#     job. These closures overlap almost entirely, and a cohort fetches that
#     shared work once and builds it once instead of once per target.
#   - attr: the flake installable to build.
#   - rootDrvPath: the derivation graph root used to plan shared work.
#   - rootSuffix: appended to the per-event prefix to form the retention root.
{
  config,
  lib,
  ...
}: let
  inherit (config.dotfiles) username;
  inherit (config.flake) deploy hosts homeConfigurations;

  baseFor = system: {
    inherit system;
    bestEffort = true;
    cohort = system;
    os =
      if lib.hasSuffix "-darwin" system
      then "macos-latest"
      else "ubuntu-latest";
    remote = !lib.hasSuffix "-darwin" system;
  };

  systemEntry = name: host: let
    profile = deploy.nodes.${name}.profiles.system.path;
  in
    baseFor host.system
    // {
      attr = ".#deploy.nodes.${name}.profiles.system.path";
      rootDrvPath = profile.drvPath;
      rootSuffix = "${host.system}/${host.os}-${name}";
    };

  homeEntry = homeName: let
    hostname = lib.last (lib.splitString "@" homeName);
    inherit (hosts.${hostname}) system;
    profile = deploy.nodes.${hostname}.profiles.${username}.path;
  in
    baseFor system
    // {
      attr = ".#deploy.nodes.${hostname}.profiles.${username}.path";
      rootDrvPath = profile.drvPath;
      rootSuffix = "${system}/home-${hostname}";
    };

  profileEntries =
    lib.mapAttrsToList systemEntry hosts
    ++ map homeEntry (lib.attrNames homeConfigurations);
in {
  flake.cupboardOutputs = profileEntries;
}
