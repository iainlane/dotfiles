{
  config,
  lib,
  ...
}: let
  targets = config.flake.cupboardOutputs;
  targetShape = target: removeAttrs target ["rootDrvPath"];
  sortTargets = lib.sort (left: right: builtins.lessThan left.attr right.attr);

  actual = sortTargets (map targetShape targets);
  expected = sortTargets [
    {
      attr = ".#deploy.nodes.ancaster.profiles.system.path";
      bestEffort = true;
      cohort = "aarch64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "aarch64-linux/linux-ancaster";
      system = "aarch64-linux";
    }
    {
      attr = ".#deploy.nodes.bonington.profiles.system.path";
      bestEffort = true;
      cohort = "x86_64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/nixos-bonington";
      system = "x86_64-linux";
    }
    {
      attr = ".#deploy.nodes.cripps.profiles.system.path";
      bestEffort = true;
      cohort = "x86_64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/linux-cripps";
      system = "x86_64-linux";
    }
    {
      attr = ".#deploy.nodes.florence.profiles.system.path";
      bestEffort = true;
      cohort = "x86_64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/linux-florence";
      system = "x86_64-linux";
    }
    {
      attr = ".#deploy.nodes.melton.profiles.system.path";
      bestEffort = true;
      cohort = "aarch64-darwin";
      os = "macos-latest";
      remote = false;
      rootSuffix = "aarch64-darwin/darwin-melton";
      system = "aarch64-darwin";
    }
    {
      attr = ".#deploy.nodes.sherwood.profiles.system.path";
      bestEffort = true;
      cohort = "x86_64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/linux-sherwood";
      system = "x86_64-linux";
    }
    {
      attr = ".#deploy.nodes.ancaster.profiles.laney.path";
      bestEffort = true;
      cohort = "aarch64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "aarch64-linux/home-ancaster";
      system = "aarch64-linux";
    }
    {
      attr = ".#deploy.nodes.bonington.profiles.laney.path";
      bestEffort = true;
      cohort = "x86_64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/home-bonington";
      system = "x86_64-linux";
    }
    {
      attr = ".#deploy.nodes.cripps.profiles.laney.path";
      bestEffort = true;
      cohort = "x86_64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/home-cripps";
      system = "x86_64-linux";
    }
    {
      attr = ".#deploy.nodes.florence.profiles.laney.path";
      bestEffort = true;
      cohort = "x86_64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/home-florence";
      system = "x86_64-linux";
    }
    {
      attr = ".#deploy.nodes.melton.profiles.laney.path";
      bestEffort = true;
      cohort = "aarch64-darwin";
      os = "macos-latest";
      remote = false;
      rootSuffix = "aarch64-darwin/home-melton";
      system = "aarch64-darwin";
    }
    {
      attr = ".#deploy.nodes.sherwood.profiles.laney.path";
      bestEffort = true;
      cohort = "x86_64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/home-sherwood";
      system = "x86_64-linux";
    }
  ];

  metadataCheckSystem = lib.head config.systems;
in {
  perSystem = {
    pkgs,
    system,
    ...
  }: let
    systemTargets = lib.filter (target: target.system == system) targets;

    mkRootDrvPathCheck = target: let
      targetName = lib.last (lib.splitString "/" target.rootSuffix);
      checkName = "cupboard-target-${targetName}";
      validRootDrvPath =
        target ? rootDrvPath
        && lib.isString target.rootDrvPath
        && lib.hasPrefix "/nix/store/" target.rootDrvPath
        && lib.hasSuffix ".drv" target.rootDrvPath;
    in
      lib.nameValuePair checkName (
        if validRootDrvPath
        then pkgs.runCommandLocal checkName {} "touch $out"
        else throw "Cupboard target ${target.attr} lacks a derivation path"
      );

    rootDrvPathChecks = builtins.listToAttrs (map mkRootDrvPathCheck systemTargets);

    metadataCheck = lib.optionalAttrs (system == metadataCheckSystem) {
      cupboard-targets =
        if actual == expected
        then pkgs.runCommandLocal "cupboard-targets" {} "touch $out"
        else throw "Cupboard target set differs from the configured hosts";
    };
  in {
    checks = metadataCheck // rootDrvPathChecks;
  };
}
