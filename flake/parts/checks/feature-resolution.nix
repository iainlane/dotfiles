# Checks feature resolution against fixtures, and the class-module merge
# against the live registry.
#
# The fixtures are attribute sets shaped like evaluated `flake.features`
# entries. Each assertion compares the complete module list the resolver
# returns, including its order. Which definition of an option wins after
# resolution is decided by the module system and is not tested here.
#
# The live assertion reads the `ai` feature, whose Home Manager class is
# defined in three files, and checks that every file's definitions reach the
# merged module tagged with the file that made them.
#
# Each assertion is a `{ name; pass; }` attribute set so the check can report
# all failures together.
{
  config,
  inputs,
  ...
}: let
  inherit (inputs.nixpkgs) lib;
  helpers = import ../../../lib/helpers.nix {inherit inputs;};

  # A module imported as a directory records the directory as its file, so
  # the comparison is on the directory of each defining `default.nix`.
  aiHomeManager = config.flake.features.ai.homeManager;
  definingDirectory = module:
    lib.removeSuffix "/default.nix" (lib.head (lib.splitString ", via option " module._file));
  aiDefiningDirectories = lib.sort lib.lessThan (lib.unique (map definingDirectory aiHomeManager.imports));
  expectedAiDirectories = lib.sort lib.lessThan (map toString [
    ../../../modules/ai
    ../../../modules/ai/claude-code
    ../../../modules/ai/codex
  ]);

  mkFeature = name: attrs:
    {
      inherit name;
      includes = [];
      nixos = null;
      darwin = null;
      systemManager = null;
      homeManager = null;
      system = null;
      os = {};
    }
    // attrs;

  resolve = class: os: features:
    helpers.resolveFeatures {
      inherit class;
      hostConfig = {inherit os features;};
    };

  throws = expr: !(builtins.tryEval (builtins.deepSeq expr true)).success;

  git = mkFeature "git" {
    homeManager = "git-home";
    os.linux.homeManager = "git-linux";
  };
  gh = mkFeature "gh" {
    includes = [git];
    homeManager = "gh-home";
  };
  borgmatic = mkFeature "borgmatic" {nixos = "borgmatic-nixos";};
  base = mkFeature "base" {
    includes = [gh git];
    nixos = "base-nixos";
    systemManager = "base-system-manager";
    system = "base-system";
    homeManager = "base-home";
    os.nixos.includes = [borgmatic];
  };

  assertions = [
    {
      name = "a feature's includes come before it, and a feature reached twice appears once";
      pass = resolve "homeManager" "darwin" [base] == ["git-home" "gh-home" "base-home"];
    }
    {
      name = "OS-scoped Home Manager content applies only on that OS";
      pass =
        resolve "homeManager" "linux" [git]
        == ["git-home" "git-linux"]
        && resolve "homeManager" "darwin" [git] == ["git-home"];
    }
    {
      name = "OS-scoped includes are followed only on that OS";
      pass =
        resolve "nixos" "nixos" [base]
        == ["borgmatic-nixos" "base-nixos" "base-system"]
        && resolve "nixos" "linux" [base] == ["base-nixos"];
    }
    {
      name = "system content goes to the class that builds the host";
      pass =
        resolve "systemManager" "linux" [base]
        == ["base-system-manager" "base-system"]
        && resolve "systemManager" "nixos" [base] == ["base-system-manager"]
        && resolve "homeManager" "linux" [base] == ["git-home" "git-linux" "gh-home" "base-home"];
    }
    {
      name = "feature names follow composition order";
      pass =
        helpers.featureNames {
          features = [base];
          os = "nixos";
        }
        == ["git" "gh" "borgmatic" "base"];
    }
    {
      name = "an include cycle is rejected";
      pass = let
        alpha = mkFeature "alpha" {includes = [beta];};
        beta = mkFeature "beta" {includes = [alpha];};
      in
        throws (resolve "nixos" "nixos" [alpha]);
    }
    {
      name = "a class defined in several files merges every file's modules, each tagged with its file";
      pass = aiDefiningDirectories == expectedAiDirectories;
    }
  ];

  failures = lib.filter (a: !a.pass) assertions;
  report = lib.concatMapStringsSep "\n" (a: "  ✗ ${a.name}") failures;
in {
  perSystem = {pkgs, ...}: {
    checks.feature-resolution =
      if failures == []
      then pkgs.runCommandLocal "feature-resolution" {} "touch $out"
      else throw "feature resolution checks failed:\n${report}";
  };
}
