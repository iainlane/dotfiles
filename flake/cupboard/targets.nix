# Build and publish deploy profiles, packages and checks in strict cohorts.
# Targets for the same system share a build invocation and a Nix store.
#
# Public targets omit deploy profiles and checks that read the private secrets
# input. Fork pull requests and merge groups build this subset without publishing.
#
# Linux targets build on nixbuild.net. Darwin runners also enable those
# builders for Linux guest dependencies. A check is left out on a Linux system
# when it requires a system feature, such as `kvm`, that nixbuild.net does not
# support on that system.
{
  config,
  lib,
  featureResolver,
  ...
}: let
  inherit (config.dotfiles) username;
  inherit (config.flake) deploy;
  inherit (config.dotfiles) hosts;
  inherit (import ../../lib/ci.nix) validationSystem;
  nixbuild = import ../../lib/nixbuild.nix {inherit lib;};

  baseFor = system: let
    platform = featureResolver.contextForSystem system;
  in {
    inherit system;
    bestEffort = false;
    cohort = system;
    os =
      if featureResolver.isDarwin platform
      then "macos-latest"
      else if featureResolver.isAarch64 platform
      then "ubuntu-24.04-arm"
      else "ubuntu-latest";
    remote = true;
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

  homeEntry = name: host: let
    profile = deploy.nodes.${name}.profiles.${username}.path;
  in
    baseFor host.system
    // {
      attr = ".#deploy.nodes.${name}.profiles.${username}.path";
      rootDrvPath = profile.drvPath;
      rootSuffix = "${host.system}/home-${name}";
    };

  profileEntries =
    lib.mapAttrsToList systemEntry hosts
    ++ lib.mapAttrsToList homeEntry hosts;

  deployToolEntries =
    map
    (system:
      baseFor system
      // {
        attr = ".#packages.${system}.deploy-rs";
        rootDrvPath = config.flake.packages.${system}.deploy-rs.drvPath;
        rootSuffix = "${system}/deploy-rs";
      })
    (lib.sort builtins.lessThan (lib.unique (map (host: host.system) (lib.attrValues hosts))));

  outputEntry = system: attr: suffix: package:
    baseFor system
    // {
      inherit attr;
      rootDrvPath = package.drvPath;
      rootSuffix = "${system}/${suffix}";
    };

  validationEntry = outputEntry validationSystem;

  packageEntry =
    validationEntry
    ".#packages.${validationSystem}.local-packages"
    "packages"
    config.flake.packages.${validationSystem}.local-packages;

  buildable = system: check:
    featureResolver.isDarwin (featureResolver.contextForSystem system) || nixbuild.canBuild system check;

  checkEntriesFor = system: systemChecks:
    lib.mapAttrsToList
    (name: outputEntry system ".#checks.${system}.${name}" "checks-${name}")
    (lib.filterAttrs (_: check: buildable system check && (!(check.ci.runOnce or false) || system == validationSystem)) systemChecks);

  checks = config.flake.checks;
  checkEntries = lib.concatLists (lib.mapAttrsToList checkEntriesFor checks);
  publicCheckEntries = lib.concatLists (lib.mapAttrsToList
    (system: systemChecks:
      checkEntriesFor system (lib.filterAttrs
        (name: _: !(lib.hasPrefix "host-evaluation-" name || lib.hasPrefix "deploy-" name || lib.hasPrefix "falcon-kernel-" name))
        systemChecks))
    checks);

  slowCheckEntries =
    lib.mapAttrsToList
    (name:
      validationEntry
      ".#legacyPackages.${validationSystem}.slowChecks.${name}"
      "slow-checks-${name}")
    (lib.filterAttrs (_: buildable validationSystem) config.flake.legacyPackages.${validationSystem}.slowChecks);
in {
  flake = {
    cupboardOutputs = profileEntries ++ deployToolEntries ++ [packageEntry] ++ checkEntries ++ slowCheckEntries;
    cupboardPublicOutputs = [packageEntry] ++ publicCheckEntries ++ slowCheckEntries;
  };
}
