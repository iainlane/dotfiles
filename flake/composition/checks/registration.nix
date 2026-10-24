{
  lib,
  featureResolver,
  definitions,
}: let
  inspect = import ../registration.nix {
    inherit lib;
    inherit (featureResolver) classes;
  };
  fixture = file: value: {inherit file value;};
  valid = inspect [
    (fixture "/src/features/example/default.nix" {example.homeManager = throw "A module body was evaluated.";})
    (fixture "/src/features/example/child/default.nix" {example.child.homeManager = {};})
    (fixture "/src/features/example/default.nix" {
      example = {};
      example-peer.includes = [];
    })
    (fixture "/src/features/example/default.nix" {
      example = {
        includes = [];
        child.homeManager = {};
      };
    })
    (fixture "/src/features/example/child.nix" (lib.mkMerge [
      {example.first.homeManager = {};}
      (lib.mkIf (throw "A condition was evaluated.") {example.second.homeManager = {};})
    ]))
  ];
  invalid = inspect [
    (fixture "/src/features/example/child.nix" {example.homeManager = {};})
    (fixture "/src/features/other/default.nix" {example.child.homeManager = {};})
    (fixture "/src/elsewhere.nix" {example = {};})
    (fixture "/src/flake/host-assembly/default.nix" {host-assembly.checks = {};})
  ];
  wrappers = {
    after = lib.mkAfter;
    before = lib.mkBefore;
    conditional = lib.mkIf (throw "A condition was evaluated.");
    defined = value:
      lib.mkDefinition {
        file = "/src/features/example/child.nix";
        inherit value;
      };
    merged = value: lib.mkMerge [{child.homeManager = throw "A child module body was evaluated.";} value];
    overridden = lib.mkOverride 25;
  };
  inspectContribution = file: contribution:
    inspect
    (lib.evalModules {
      modules = [
        ../schema.nix
        {
          _file = file;
          dotfiles.features.example = contribution;
        }
      ];
    }).options.dotfiles.features.definitionsWithLocations;
  wrapperResults =
    lib.mapAttrs (_: wrap: {
      root = inspectContribution "/src/features/example/child.nix" (wrap {homeManager = throw "A module body was evaluated.";});
      child = inspectContribution "/src/features/example/child.nix" (wrap {child.homeManager = throw "A child module body was evaluated.";});
    })
    wrappers;
  expectedWrapperResults =
    lib.mapAttrs (_: _: {
      root = [
        {
          name = "example";
          file = "/src/features/example/child.nix";
          valid = false;
        }
      ];
      child = [];
    })
    wrappers;
  functionResults = {
    entry = inspectContribution "/src/features/example/default.nix" (_: throw "A feature module was evaluated.");
    child = inspectContribution "/src/features/example/child.nix" (_: throw "A feature module was evaluated.");
  };
  errors = inspect definitions;
  report = lib.concatMapStringsSep "\n" (entry: "${entry.file}: invalid definition of ${entry.name}") errors;
  fixturePass =
    valid
    == []
    && wrapperResults == expectedWrapperResults
    && functionResults
    == {
      entry = [];
      child = [
        {
          name = "example";
          file = "/src/features/example/child.nix";
          valid = false;
        }
      ];
    }
    && map (entry: {inherit (entry) name file valid;}) invalid
    == [
      {
        name = "example";
        file = "/src/features/example/child.nix";
        valid = false;
      }
      {
        name = "example";
        file = "/src/features/other/default.nix";
        valid = false;
      }
      {
        name = "example";
        file = "/src/elsewhere.nix";
        valid = false;
      }
      {
        name = "host-assembly";
        file = "/src/flake/host-assembly/default.nix";
        valid = false;
      }
    ];
in
  {pkgs, ...}: {
    feature-registration = assert lib.assertMsg fixturePass (builtins.toJSON {inherit valid invalid wrapperResults functionResults;});
      pkgs.runCommandLocal "feature-registration" {inherit report;} ''
        if [ -n "$report" ]; then printf '%s\n' "$report" >&2; exit 1; fi
        touch "$out"
      '';
  }
