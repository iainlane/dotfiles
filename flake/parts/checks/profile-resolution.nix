# Checks profile and feature resolution.
#
# Fixtures cover module composition, profile requirements, duplicate profiles,
# and invalid module types. Assertions against the configured profiles and
# modules detect unknown features and invalid operating-system keys.
#
# The fixture assertions compare complete module lists, including their order.
# Nix module merge functions and priorities determine option precedence after
# resolution, which this check does not test.
#
# Each assertion is a `{ name; pass; }` attribute set so the check can report all
# failures together. Assertions over the live configuration can also include
# the offending entries in a `detail` list.
{
  inputs,
  config,
  lib,
  ...
}: let
  helpers = import ../../../lib/helpers.nix {inherit inputs;};

  # Fixtures representing `flake.modules` and `flake.profiles`.
  emptyModule = {
    homeManagerModules = [];
    systemManagerModules = [];
    nixosModules = [];
    os = {};
  };
  fixtureModules = {
    # A base Home Manager export.
    alpha = emptyModule // {homeManagerModules = ["alpha-home"];};
    # A NixOS export.
    beta = emptyModule // {nixosModules = ["beta-nixos"];};
    # Base and Linux-specific Home Manager exports.
    gamma =
      emptyModule
      // {
        homeManagerModules = ["gamma-home"];
        os.linux.homeManagerModules = ["gamma-linux"];
      };
    # A base export selected by an OS-specific profile feature.
    delta = emptyModule // {homeManagerModules = ["delta-home"];};
    # Base and Linux-specific exports selected by an OS-specific profile feature.
    zeta =
      emptyModule
      // {
        homeManagerModules = ["zeta-home"];
        os.linux.homeManagerModules = ["zeta-linux"];
      };
    # A system-manager export.
    sysfeat = emptyModule // {systemManagerModules = ["sys-mod"];};
  };
  mkProfile = attrs:
    {
      homeManagerModule = null;
      systemManagerModule = null;
      nixosModule = null;
      features = [];
      requires = [];
      os = {};
    }
    // attrs;
  mkHost = os: profiles: {
    hostname = "fixture";
    inherit os profiles;
  };
  # Resolves the fixture profile named `p` for the given module type and host OS.
  resolve = moduleType: os: profile:
    helpers.mkModules {
      inherit moduleType;
      hostConfig = mkHost os ["p"];
      profiles = {p = profile;};
      modules = fixtureModules;
    };
  throws = expr: !(builtins.tryEval (builtins.deepSeq expr true)).success;

  # Feature and OS references from the configured profiles and modules.
  profileFeatureNames = profile:
    (profile.features or [])
    ++ lib.concatLists (lib.mapAttrsToList (_: osCfg: osCfg.features or []) (profile.os or {}));
  referencedFeatures =
    lib.unique (lib.concatLists (lib.mapAttrsToList (_: profileFeatureNames) config.flake.profiles));
  knownFeatures = lib.attrNames config.flake.modules;
  unknownFeatures = lib.filter (name: !builtins.elem name knownFeatures) referencedFeatures;

  knownOs = config.dotfiles.operatingSystems;
  badOsKeysIn = registry:
    lib.concatLists (lib.mapAttrsToList (
        name: entry:
          map (osKey: "${name}.os.${osKey}")
          (lib.filter (osKey: !builtins.elem osKey knownOs) (lib.attrNames (entry.os or {})))
      )
      registry);
  badProfileOsKeys = badOsKeysIn config.flake.profiles;
  badFeatureOsKeys = badOsKeysIn config.flake.modules;

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
      name = "an OS-scoped profile feature contributes both its base and OS exports";
      pass =
        resolve "homeManagerModule" "linux" (mkProfile {os.linux.features = ["zeta"];})
        == [{imports = ["zeta-home" "zeta-linux"];}];
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
      name = "an unknown module type is rejected";
      pass = throws (resolve "homeManagerModules" "linux" (mkProfile {features = ["alpha"];}));
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
      detail = unknownFeatures;
    }
    {
      name = "every profile OS scope key is a known operating system";
      pass = badProfileOsKeys == [];
      detail = badProfileOsKeys;
    }
    {
      name = "every feature OS scope key is a known operating system";
      pass = badFeatureOsKeys == [];
      detail = badFeatureOsKeys;
    }
  ];

  failures = lib.filter (a: !a.pass) assertions;
  describeFailure = a:
    "  ✗ ${a.name}"
    + lib.concatMapStrings (d: "\n      ${d}") (a.detail or []);
  report = lib.concatMapStringsSep "\n" describeFailure failures;
in {
  perSystem = {pkgs, ...}: {
    checks.profile-resolution =
      if failures == []
      then pkgs.runCommandLocal "profile-resolution" {} "touch $out"
      else throw "profile resolution checks failed:\n${report}";
  };
}
