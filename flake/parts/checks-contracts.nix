# Architecture contract checks.
#
# The formatting/linting checks in checks.nix keep the source tidy; these keep
# the *architecture* honest. They evaluate the profile/feature resolution
# contract directly so `nix flake check` fails on a broken contract (an unknown
# feature name, a duplicate profile, a mis-scoped OS key, a regression in name
# resolution or merge order) rather than only on a bad build much later.
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
    # base-only Home Manager export.
    alpha = emptyModule // {homeManagerModules = ["alpha-home"];};
    # NixOS export.
    beta = emptyModule // {nixosModules = ["beta-nixos"];};
    # both a base export and an OS-specific export.
    gamma =
      emptyModule
      // {
        homeManagerModules = ["gamma-home"];
        os.linux.homeManagerModules = ["gamma-linux"];
      };
    # base export, reached only via an OS-scoped profile feature.
    delta = emptyModule // {homeManagerModules = ["delta-home"];};
    # system-manager export.
    sysfeat = emptyModule // {systemManagerModules = ["sys-mod"];};
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
  mkHost = os: profiles: {
    hostname = "fixture";
    inherit os profiles;
  };
  # Resolve one profile "p" for the given target and host OS.
  resolve = moduleType: os: profile:
    helpers.mkModules {
      inherit moduleType;
      hostConfig = mkHost os ["p"];
      profiles = {p = profile;};
      modules = fixtureModules;
    };
  throws = expr: !(builtins.tryEval (builtins.deepSeq expr true)).success;

  # --- real config: feature names and OS keys must be valid ---
  profileFeatureNames = profile:
    (profile.features or [])
    ++ lib.concatLists (lib.mapAttrsToList (_: osCfg: osCfg.features or []) (profile.os or {}));
  referencedFeatures =
    lib.unique (lib.concatLists (lib.mapAttrsToList (_: profileFeatureNames) config.flake.profiles));
  knownFeatures = lib.attrNames config.flake.modules;
  unknownFeatures = lib.filter (name: !builtins.elem name knownFeatures) referencedFeatures;

  knownOs = config.dotfiles.operatingSystems;
  badOsKeys = lib.concatLists (lib.mapAttrsToList (
      profileName: profile:
        map (osKey: "${profileName}.os.${osKey}")
        (lib.filter (osKey: !builtins.elem osKey knownOs) (lib.attrNames (profile.os or {})))
    )
    config.flake.profiles);

  assertions = [
    {
      name = "a base feature resolves to its flake.modules value";
      pass = resolve "homeManagerModule" "linux" (mkProfile {features = ["alpha"];}) == [{imports = ["alpha-home"];}];
    }
    {
      name = "a feature's base and host-OS exports are both included";
      pass =
        resolve "homeManagerModule" "linux" (mkProfile {features = ["gamma"];})
        == [{imports = ["gamma-home"];} {imports = ["gamma-linux"];}];
    }
    {
      name = "OS-scoped profile features resolve for the host OS";
      pass =
        resolve "homeManagerModule" "linux" (mkProfile {os.linux.features = ["delta"];})
        == [{imports = ["delta-home"];}];
    }
    {
      name = "legacy value-based modules are appended after resolved features";
      pass =
        resolve "homeManagerModule" "linux" (mkProfile {
          features = ["alpha"];
          modules = [(emptyModule // {homeManagerModules = ["epsilon-home"];})];
        })
        == [{imports = ["alpha-home" "epsilon-home"];}];
    }
    {
      name = "nixosModule resolution collects nixos feature exports";
      pass = resolve "nixosModule" "nixos" (mkProfile {features = ["beta"];}) == [{imports = ["beta-nixos"];}];
    }
    {
      name = "systemManagerModule resolution collects system-manager exports";
      pass = resolve "systemManagerModule" "linux" (mkProfile {features = ["sysfeat"];}) == [{imports = ["sys-mod"];}];
    }
    {
      name = "an unknown feature name is rejected";
      pass = throws (resolve "homeManagerModule" "linux" (mkProfile {features = ["does-not-exist"];}));
    }
    {
      name = "a profile declared twice on one host is rejected";
      pass = throws (helpers.mkModules {
        moduleType = "homeManagerModule";
        hostConfig = mkHost "linux" ["p" "p"];
        profiles = {p = mkProfile {};};
        modules = fixtureModules;
      });
    }
    {
      name = "a profile that requires itself is rejected";
      pass = throws (helpers.validateProfileRequirements {
        hostConfig = mkHost "linux" ["p"];
        profiles = {p = mkProfile {requires = ["p"];};};
      });
    }
    {
      name = "a missing required profile is rejected";
      pass = throws (helpers.validateProfileRequirements {
        hostConfig = mkHost "linux" ["p"];
        profiles = {
          p = mkProfile {requires = ["q"];};
          q = mkProfile {};
        };
      });
    }
    {
      name = "a satisfied requirement passes";
      pass =
        (helpers.validateProfileRequirements {
          hostConfig = mkHost "linux" ["p" "q"];
          profiles = {
            p = mkProfile {requires = ["q"];};
            q = mkProfile {};
          };
        })
        == true;
    }
    {
      name = "every profile feature name exists in flake.modules";
      pass = unknownFeatures == [];
    }
    {
      name = "every profile OS scope key is a known operating system";
      pass = badOsKeys == [];
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
