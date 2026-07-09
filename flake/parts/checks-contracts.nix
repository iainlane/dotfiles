# Architecture contract checks.
#
# The formatting/linting checks in checks.nix keep the source tidy; these keep
# the *architecture* honest. They evaluate the profile/feature resolution
# contract directly so `nix flake check` fails on a broken contract (an unknown
# feature name, a duplicate profile, a regression in name resolution) rather
# than only on a bad build much later.
#
# Everything here is pure Nix evaluation — no shelling out to `nix eval`, which
# is unavailable inside a pure `nix flake check`. Each assertion is a
# `{ name; pass; }` pair; if any fail the derivation throws with a readable
# report naming them.
{
  inputs,
  config,
  lib,
  ...
}: let
  helpers = import ../../lib/helpers.nix {inherit inputs;};

  # --- fixtures: minimal stand-ins for flake.modules / flake.profiles ---
  emptyModule = {
    homeManagerModules = [];
    systemManagerModules = [];
    nixosModules = [];
    os = {};
  };
  fixtureModules = {
    alpha = emptyModule // {homeManagerModules = ["alpha-home"];};
    beta = emptyModule // {nixosModules = ["beta-nixos"];};
  };
  mkProfile = attrs:
    {
      homeManagerModule = null;
      systemManagerModule = null;
      nixosModule = null;
      features = [];
      modules = [];
      requires = [];
      os = {};
    }
    // attrs;
  fixtureProfiles = {
    demo = mkProfile {features = ["alpha"];};
  };
  fixtureHost = {
    hostname = "fixture";
    os = "linux";
    profiles = ["demo"];
  };

  throws = expr: !(builtins.tryEval (builtins.deepSeq expr true)).success;

  # --- real config: feature names must resolve against flake.modules ---
  profileFeatureNames = profile:
    (profile.features or [])
    ++ lib.concatLists (lib.mapAttrsToList (_: osCfg: osCfg.features or []) (profile.os or {}));
  referencedFeatures =
    lib.unique (lib.concatLists (lib.mapAttrsToList (_: profileFeatureNames) config.flake.profiles));
  knownFeatures = lib.attrNames config.flake.modules;
  unknownFeatures = lib.filter (name: !builtins.elem name knownFeatures) referencedFeatures;

  assertions = [
    {
      name = "features resolve to their flake.modules values";
      pass =
        helpers.mkModules {
          moduleType = "homeManagerModule";
          hostConfig = fixtureHost;
          profiles = fixtureProfiles;
          modules = fixtureModules;
        }
        == [{imports = ["alpha-home"];}];
    }
    {
      name = "an unknown feature name is rejected";
      pass = throws (helpers.mkModules {
        moduleType = "homeManagerModule";
        hostConfig = fixtureHost;
        profiles = {demo = mkProfile {features = ["does-not-exist"];};};
        modules = fixtureModules;
      });
    }
    {
      name = "a profile declared twice on one host is rejected";
      pass = throws (helpers.activeProfileNames (fixtureHost // {profiles = ["demo" "demo"];}));
    }
    {
      name = "every profile feature name exists in flake.modules";
      pass = unknownFeatures == [];
    }
  ];

  failures = lib.filter (a: !a.pass) assertions;
  report = lib.concatMapStringsSep "\n" (a: "  ✗ ${a.name}") failures;
in {
  perSystem = {pkgs, ...}: {
    checks.profile-contracts =
      if failures == []
      then pkgs.runCommandLocal "profile-contracts" {} "touch $out"
      else throw "profile-contract checks failed:\n${report}";
  };
}
