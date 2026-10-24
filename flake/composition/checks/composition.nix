{
  featureResolver,
  lib,
  ...
}: let
  inherit (featureResolver) when;
  linux = featureResolver.contextForSystem "x86_64-linux";
  darwin = featureResolver.contextForSystem "aarch64-darwin";
  host = featureResolver.contextForHost {
    name = "fixture";
    system = "x86_64-linux";
    os = "generic-linux";
    channel = "stable";
  };
  child = {
    name = "example.child";
    includes = [];
    homeManager = "child";
  };
  example = {
    name = "example";
    homeManager = "base";
    includes = [
      (when featureResolver.isLinux [{homeManager = "linux";}])
      (when featureResolver.isDarwin [{homeManager = "darwin";}])
      (when featureResolver.isGenericLinux [child])
    ];
  };
  resolve = context:
    featureResolver.modulesFor {
      class = "homeManager";
      inherit context;
      inherit
        ((featureResolver.closure {
          inherit context;
          features = [example];
        }))
        ordered
        ;
    };
  assertions = [
    {
      name = "shared contexts select kernel fragments without host metadata";
      pass = resolve linux == ["linux" "base"] && resolve darwin == ["darwin" "base"];
    }
    {
      name = "host predicates select registered children";
      pass = resolve host == ["linux" "child" "base"];
    }
    {
      name = "inline fragments are absent from public feature membership";
      pass =
        featureResolver.featureNames {
          context = host;
          features = [example];
        }
        == ["example.child" "example"];
    }
    {
      name = "fragment identities remain stable when other guards are skipped";
      pass = let
        identities = context:
          map (entry: entry.identity) (featureResolver.contributionsFor {
            class = "homeManager";
            inherit context;
            inherit
              ((featureResolver.closure {
                inherit context;
                features = [example];
              }))
              ordered
              ;
          });
      in
        lib.take 1 (identities linux) == lib.take 1 (identities host);
    }
    {
      name = "missing required predicate arguments skip guards while optional arguments use defaults";
      pass =
        featureResolver.select linux [
          (when ({hostConfig}: hostConfig.name == "fixture") ["host"])
          (when ({hostConfig ? null}: hostConfig == null) ["shared"])
          (when ({systemConfig}: builtins.deepSeq systemConfig (throw "evaluated configuration was passed to selection")) ["invalid"])
        ]
        == ["shared"];
    }
    {
      name = "equal inline fragments retain separate identities under different owners";
      pass = let
        fragment.homeManager = "fragment";
        owners = map (name: {
          inherit name;
          includes = [fragment];
        }) ["first" "second"];
      in
        featureResolver.modulesFor {
          class = "homeManager";
          context = linux;
          inherit
            ((featureResolver.closure {
              features = owners;
              context = linux;
            }))
            ordered
            ;
        }
        == ["fragment" "fragment"];
    }
    {
      name = "platform and host predicates distinguish kernels, OSes and channels";
      pass =
        {
          linux = featureResolver.isLinux linux;
          darwin = featureResolver.isDarwin darwin;
          nixos = featureResolver.isNixos host;
          generic = featureResolver.isGenericLinux host;
          stable = featureResolver.isStable host;
          unstable = featureResolver.isUnstable host;
          arm = featureResolver.isAarch64 darwin;
          x86 = featureResolver.isx86_64 linux;
        }
        == {
          linux = true;
          darwin = true;
          nixos = false;
          generic = true;
          stable = true;
          unstable = false;
          arm = true;
          x86 = true;
        };
    }
  ];
  failures = lib.filter (assertion: !assertion.pass) assertions;
  report = lib.concatMapStringsSep "\n" (assertion: assertion.name) failures;
in
  {pkgs, ...}:
    {
      checks.feature-composition = pkgs.runCommandLocal "feature-composition" {inherit report;} ''
        if [ -n "$report" ]; then
          printf '%s\n' "$report" >&2
          exit 1
        fi
        touch "$out"
      '';
    }.checks
