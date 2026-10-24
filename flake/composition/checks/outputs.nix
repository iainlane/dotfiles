{
  inputs,
  lib,
  featureResolver,
  ...
}: let
  outputs = import ../../../lib/feature-outputs.nix {inherit inputs lib featureResolver;};
  throws = value: !(builtins.tryEval (builtins.deepSeq value true)).success;
in
  {
    pkgs,
    system,
    ...
  }:
    (
      let
        context =
          featureResolver.contextForSystem system
          // {
            hostConfig = {
              name = "fixture";
              channel = "stable";
            };
            systemConfig.answer = 42;
            homeConfig.answer = 43;
          };
        module = {
          hostConfig,
          systemConfig,
          homeConfig,
        }: {pkgs, ...}: {
          "${hostConfig.name}" = pkgs.writeText "answers" "${toString systemConfig.answer}:${toString homeConfig.answer}";
        };
        feature = {
          name = "fixture";
          includes = [];
          checks = module;
        };
        entries = outputs.contributions {
          class = "checks";
          inherit context;
          ordered = [feature];
        };
        evaluate = class: modules:
          outputs.evaluate {
            inherit class modules;
            args = {inherit pkgs system;};
          };
        package = pkgs.writeText "fixture" "ok";
        result = evaluate "checks" (map (outputs.bind context) entries);
        fixture = {
          name = "outputs";
          includes = [(featureResolver.when featureResolver.isGenericLinux [{legacyPackages.selectedOnHost = true;}])];
          packages = {example = package;};
          checks = {example = package;};
          devShells = {example = package;};
          apps = {example.program = "/bin/example";};
          legacyPackages = [
            ({pkgs, ...}: {shared = [pkgs.channelTag];})
            ({platform}: {system, ...}: {
              platformSystem = platform.system;
              evaluationSystem = system;
            })
            ({
              hostConfig,
              systemConfig,
              homeConfig,
            }: {pkgs, ...}: {
              hosts.${hostConfig.name} = {
                channel = pkgs.channelTag;
                systemValue = systemConfig.answer;
                homeValue = homeConfig.answer;
              };
            })
          ];
        };
        extra = {
          name = "standalone";
          includes = [];
          legacyPackages.standalone = true;
        };
        fixtureHost = name: channel: {
          inherit name channel system;
          os = "generic-linux";
          features = [fixture];
          excludes = [];
        };
        combined = outputs.forSystem {
          inherit system;
          pkgs = pkgs // {channelTag = "unstable";};
          pkgs-stable = pkgs // {channelTag = "stable";};
          hosts = {
            first = fixtureHost "first" "stable";
            second = fixtureHost "second" "unstable";
          };
          flakeSystem.includes = [fixture extra];
          flakeSystem.excludes = [];
          hostResults = lib.genAttrs ["first" "second"] (_: {
            configuration.config.answer = 42;
            homeConfiguration.config.answer = 43;
          });
        };
        withoutHosts = outputs.forSystem {
          inherit system pkgs;
          pkgs-stable = pkgs;
          hosts = {};
          flakeSystem.includes = [extra];
          flakeSystem.excludes = [];
          hostResults = throw "Shared output evaluation forced host configurations";
        };
        collisionFeature = {
          name = "collision";
          includes = [];
          legacyPackages = {hostConfig}: _: {collision = hostConfig.name;};
        };
        colliding = outputs.forSystem {
          inherit system pkgs;
          pkgs-stable = pkgs;
          hosts = lib.genAttrs ["first" "second"] (name: (fixtureHost name "unstable") // {features = [collisionFeature];});
          flakeSystem.includes = [];
          flakeSystem.excludes = [];
          hostResults = throw "Unused host configurations were forced";
        };
        excluded = outputs.forSystem {
          inherit system pkgs;
          pkgs-stable = pkgs;
          hosts = {};
          flakeSystem.includes = [
            {
              name = "parent";
              includes = [extra];
            }
          ];
          flakeSystem.excludes = [extra];
          hostResults = throw "Shared selection forced host configurations";
        };
        pathEntries = class: paths:
          outputs.contributions {
            inherit class context;
            ordered = [
              {
                name = "paths";
                includes = [];
                ${class} = paths;
              }
            ];
          };
        assertions = [
          {
            name = "host output keys must be qualified when values differ";
            pass = throws colliding.legacyPackages;
          }
          {
            name = "shared exclusions remove reachable output contributions";
            pass = excluded.legacyPackages == {};
          }
          {
            name = "path modules retain native import deduplication";
            pass = evaluate "legacyPackages" (map (outputs.bind context) (pathEntries "legacyPackages" [../../../flake/fixtures/feature-outputs/ordinary.nix ../../../flake/fixtures/feature-outputs/ordinary.nix])) == {paths = ["once"];};
          }
          {
            name = "import-only path wrappers retain native deduplication";
            pass = evaluate "legacyPackages" (map (outputs.bind context) (pathEntries "legacyPackages" [../../../flake/fixtures/feature-outputs/wrapper.nix ../../../flake/fixtures/feature-outputs/wrapper.nix])) == {paths = ["wrapper"];};
          }
          {
            name = "modules with a different class are rejected";
            pass = throws (evaluate "checks" [
              {
                _class = "packages";
                example = package;
              }
            ]);
          }
          {
            name = "context-dependent path modules bind before evaluation";
            pass = evaluate "packages" (map (outputs.bind context) (pathEntries "packages" [../../../flake/fixtures/feature-outputs/context.nix])) == {fixture = pkgs.hello;};
          }
          {
            name = "all five classes export selected contributions";
            pass =
              lib.mapAttrs (_: value: lib.attrNames value) combined
              == {
                packages = ["example"];
                checks = ["example"];
                devShells = ["example"];
                apps = ["example"];
                legacyPackages = ["evaluationSystem" "hosts" "platformSystem" "selectedOnHost" "shared" "standalone"];
              };
          }
          {
            name = "shared contributions deduplicate across roots and two hosts while host contributions use their channel";
            pass =
              combined.legacyPackages
              == {
                shared = ["unstable"];
                platformSystem = system;
                evaluationSystem = system;
                selectedOnHost = true;
                standalone = true;
                hosts = {
                  first = {
                    channel = "stable";
                    systemValue = 42;
                    homeValue = 43;
                  };
                  second = {
                    channel = "unstable";
                    systemValue = 42;
                    homeValue = 43;
                  };
                };
              };
          }
          {
            name = "standalone roots work without hosts and host configurations stay lazy";
            pass = withoutHosts.legacyPackages == {standalone = true;};
          }
          {
            name = "deferred wrappers preserve provenance for context modules";
            pass = let
              tagged = outputs.contributions {
                class = "checks";
                inherit context;
                ordered = [
                  {
                    name = "tagged";
                    includes = [];
                    checks = {
                      _file = "owner.nix";
                      imports = [module];
                    };
                  }
                ];
              };
            in
              map (entry: {
                inherit (entry) file;
                host = outputs.needsHost entry;
              })
              tagged
              == [
                {
                  file = "owner.nix";
                  host = true;
                }
              ];
          }
          {
            name = "all output classes use the registry";
            pass = featureResolver.outputClasses == ["apps" "checks" "devShells" "legacyPackages" "packages"];
          }
          {
            name = "two-layer modules bind context before normal module arguments";
            pass = outputs.needsHost (lib.head entries) && lib.attrNames result == ["fixture"];
          }
          {
            name = "shared modules do not force host configurations";
            pass =
              evaluate "packages" [
                (outputs.bind (context // {systemConfig = throw "forced";}) {
                  module = {platform}: {pkgs, ...}: {example = pkgs.writeText "platform" platform.system;};
                  file = "fixture";
                })
              ]
              != {};
          }
          {
            name = "native priorities apply to package outputs";
            pass = evaluate "packages" [{example = lib.mkDefault package;} {example = lib.mkForce pkgs.hello;}] == {example = pkgs.hello;};
          }
          {
            name = "native package conflicts fail";
            pass = throws (evaluate "packages" [{example = package;} {example = pkgs.hello;}]);
          }
          {
            name = "apps use native defaults and validation";
            pass =
              (evaluate "apps" [{example.program = "/bin/example";}]).example
              == {
                type = "app";
                program = "/bin/example";
                meta = {};
              }
              && throws (evaluate "apps" [{example.program = 42;}]);
          }
          {
            name = "shells and checks require derivations";
            pass = lib.all (class: throws (evaluate class [{example = "invalid";}])) ["checks" "devShells"];
          }
          {
            name = "legacy outputs recursively merge lists and equal leaves";
            pass =
              evaluate "legacyPackages" [
                {
                  nested = {
                    list = [1];
                    leaf = "same";
                    drv = package;
                  };
                }
                {
                  nested = {
                    list = [2];
                    leaf = "same";
                  };
                }
              ]
              == {
                nested = {
                  list = [2 1];
                  leaf = "same";
                  drv = package;
                };
              };
          }
          {
            name = "nested legacy lists respect explicit module ordering";
            pass = evaluate "legacyPackages" [{nested.list = lib.mkAfter [2];} {nested.list = lib.mkBefore [1];}] == {nested.list = [1 2];};
          }
          {
            name = "legacy conflicts fail";
            pass = throws (evaluate "legacyPackages" [{nested.leaf = 1;} {nested.leaf = 2;}]);
          }
          {
            name = "ordinary module config is class-local";
            pass =
              evaluate "legacyPackages" [
                ({config, ...}: {
                  first = 42;
                  second = config.first;
                })
              ]
              == {
                first = 42;
                second = 42;
              };
          }
        ];
        failures = lib.filter (assertion: !assertion.pass) assertions;
        report = lib.concatMapStringsSep "\n" (assertion: assertion.name) failures;
      in {
        checks.feature-outputs = pkgs.runCommandLocal "feature-outputs" {inherit report;} ''
          if [ -n "$report" ]; then printf '%s\n' "$report" >&2; exit 1; fi
          touch "$out"
        '';
      }
    ).checks
