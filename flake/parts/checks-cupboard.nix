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
      attr = ".#nixosConfigurations.bonington.config.system.build.toplevel";
      bestEffort = true;
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/nixos-bonington";
      system = "x86_64-linux";
    }
    {
      attr = ".#darwinConfigurations.melton.system";
      bestEffort = true;
      os = "macos-latest";
      remote = false;
      rootSuffix = "aarch64-darwin/darwin-melton";
      system = "aarch64-darwin";
    }
    {
      attr = ''.#homeConfigurations."laney@ancaster".activationPackage'';
      bestEffort = true;
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "aarch64-linux/home-ancaster";
      system = "aarch64-linux";
    }
    {
      attr = ''.#homeConfigurations."laney@bonington".activationPackage'';
      bestEffort = true;
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/home-bonington";
      system = "x86_64-linux";
    }
    {
      attr = ''.#homeConfigurations."laney@cripps".activationPackage'';
      bestEffort = true;
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/home-cripps";
      system = "x86_64-linux";
    }
    {
      attr = ''.#homeConfigurations."laney@florence".activationPackage'';
      bestEffort = true;
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/home-florence";
      system = "x86_64-linux";
    }
    {
      attr = ''.#homeConfigurations."laney@melton".activationPackage'';
      bestEffort = true;
      os = "macos-latest";
      remote = false;
      rootSuffix = "aarch64-darwin/home-melton";
      system = "aarch64-darwin";
    }
    {
      attr = ''.#homeConfigurations."laney@sherwood".activationPackage'';
      bestEffort = true;
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/home-sherwood";
      system = "x86_64-linux";
    }
  ];

  missingRootDrvPaths =
    map (target: target.attr)
    (lib.filter (
        target:
          !(target ? rootDrvPath)
          || !lib.hasPrefix "/nix/store/" target.rootDrvPath
          || !lib.hasSuffix ".drv" target.rootDrvPath
      )
      targets);

  failures =
    lib.optional (actual != expected) "closure target set differs from the configured hosts"
    ++ lib.optional (missingRootDrvPaths != []) "targets lack derivation paths: ${lib.concatStringsSep ", " missingRootDrvPaths}";
in {
  perSystem = {pkgs, ...}: {
    checks.cupboard-targets =
      if failures == []
      then pkgs.runCommandLocal "cupboard-targets" {} "touch $out"
      else throw "cupboard target checks failed:\n${lib.concatMapStringsSep "\n" (failure: "  - ${failure}") failures}";
  };
}
