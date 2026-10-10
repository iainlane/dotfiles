# Build and publish deploy profiles, packages and checks in strict cohorts.
# Targets for the same system share a build invocation and a Nix store.
#
# Public targets omit deploy profiles and checks that read the private secrets
# input. Fork pull requests and merge groups build this subset without publishing.
{
  config,
  lib,
  ...
}: let
  inherit (config.flake) username;
  inherit (config.flake) deploy hosts;
  validationSystem = "x86_64-linux";

  baseFor = system: {
    inherit system;
    bestEffort = false;
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

  validationEntry = attr: suffix: package:
    baseFor validationSystem
    // {
      inherit attr;
      rootDrvPath = package.drvPath;
      rootSuffix = "${validationSystem}/${suffix}";
    };

  packageEntry =
    validationEntry
    ".#packages.${validationSystem}.local-packages"
    "packages"
    config.flake.packages.${validationSystem}.local-packages;

  checkEntriesFor =
    lib.mapAttrsToList
    (name: validationEntry ".#checks.${validationSystem}.${name}" "checks-${name}");

  checks = config.flake.checks.${validationSystem};
  checkEntries = checkEntriesFor checks;
  publicCheckEntries = checkEntriesFor (lib.filterAttrs
    (name: _: !(lib.hasPrefix "host-evaluation-" name || lib.hasPrefix "deploy-" name))
    checks);

  promptEntries =
    lib.mapAttrsToList
    (name:
      validationEntry
      ".#packages.${validationSystem}.claude-prompt-conformance.tests.${name}"
      "prompt-conformance-${name}")
    config.flake.packages.${validationSystem}.claude-prompt-conformance.tests;
in {
  flake = {
    cupboardOutputs = profileEntries ++ deployToolEntries ++ [packageEntry] ++ checkEntries ++ promptEntries;
    cupboardPublicOutputs = [packageEntry] ++ publicCheckEntries ++ promptEntries;
  };
}
