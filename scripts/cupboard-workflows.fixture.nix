{
  lib,
  systems,
  inputs,
}: let
  inherit (import ../lib/ci.nix) validationSystem;
  fakePackage = name: {
    drvPath = "/nix/store/00000000000000000000000000000000-${name}.drv";
  };
  fixtureConfig.flake = {
    username = "tester";
    hosts = {
      test = {
        system = "x86_64-linux";
        os = "nixos";
      };
      mac = {
        system = "aarch64-darwin";
        os = "darwin";
      };
    };
    deploy.nodes = {
      test.profiles = {
        system.path = fakePackage "system-test";
        tester.path = fakePackage "home-test";
      };
      mac.profiles = {
        system.path = fakePackage "system-mac";
        tester.path = fakePackage "home-mac";
      };
    };
    packages = {
      aarch64-darwin.deploy-rs = fakePackage "deploy-rs-darwin";
      x86_64-linux = {
        deploy-rs = fakePackage "deploy-rs-linux";
        local-packages = fakePackage "packages";
      };
    };
    legacyPackages = lib.genAttrs systems (system: {
      slowChecks.example-slow = fakePackage "slow-${system}";
    });
    checks = lib.genAttrs systems (system:
      {
        deploy-schema = fakePackage "deploy" // {ci.runOnce = true;};
        example = fakePackage "example";
        global = fakePackage "global" // {ci.runOnce = true;};
        falcon-kernel-test = fakePackage "falcon";
        host-evaluation-home-test = fakePackage "host";
        prompt-conformance-configuration = fakePackage "configuration";
      }
      // lib.optionalAttrs (lib.hasSuffix "-linux" system) {
        kvm-build = fakePackage "kvm" // {requiredSystemFeatures = ["kvm"];};
        vm-test =
          fakePackage "vm"
          // {
            config.requiredFeatures = {
              apple-virt = false;
              kvm = true;
              nixos-test = true;
            };
          };
      });
  };
  subject = config:
    import ../flake/parts/cupboard.nix {
      inherit lib config;
      featureResolver = import ../lib/features.nix {inherit lib;};
    };
  complete = subject fixtureConfig;
  publicOnly = subject {
    flake =
      fixtureConfig.flake
      // {
        deploy = throw "Private deploy profiles were evaluated.";
        checks = lib.mapAttrs (_: checks:
          checks
          // {
            deploy-schema = throw "A private deploy check was evaluated.";
            falcon-kernel-test = throw "A private Falcon check was evaluated.";
            host-evaluation-home-test = throw "A private host check was evaluated.";
          })
        fixtureConfig.flake.checks;
      };
  };
  lazyChecksFor = system: let
    runCommandLocal = name: _: _:
      fakePackage name
      // {
        type = "derivation";
        outputs = ["out"];
      };
    config.flake = {
      username = "tester";
      hosts.fixture = {
        inherit system;
        os =
          if lib.hasSuffix "-darwin" system
          then "darwin"
          else "nixos";
        hostname = "fixture";
      };
    };
    hostResults = throw "The host configuration was forced.";
    hostChecks =
      (import ../flake/parts/checks/host-evaluation.nix {
        inherit lib config hostResults;
      }).perSystem {
        inherit system;
        pkgs = {inherit runCommandLocal;};
      };
    deployChecks = (import ../flake/parts/deploy.nix {
      inherit inputs lib config hostResults;
    }).perSystem {inherit system;};
    managedChecks =
      import ../features/hermes/managed-config-host-check.nix {
        hostConfig.name = "fixture";
        systemConfig = hostResults;
      } {
        inherit lib;
        pkgs = {inherit runCommandLocal;};
      };
  in
    hostChecks.checks // deployChecks.checks // managedChecks;
  lazyVm = lib.lazyDerivation {
    derivation = throw "The VM test derivation was forced.";
    passthru.config.requiredFeatures = {
      apple-virt = false;
      kvm = true;
      nixos-test = true;
    };
  };
  lazyChecks = lib.genAttrs systems (system:
    lazyChecksFor system
    // lib.optionalAttrs (lib.hasSuffix "-linux" system) {vm-test = lazyVm;});
  lazyTargets =
    (subject {
      flake =
        fixtureConfig.flake
        // {
          checks = lazyChecks;
          legacyPackages.${validationSystem}.slowChecks.vm-test = lazyVm;
        };
    }).flake.cupboardOutputs;
  nixbuild = import ../lib/nixbuild.nix {inherit lib;};
in {
  inherit validationSystem;
  checkSystems = lib.attrNames fixtureConfig.flake.checks;
  outputs = complete.flake.cupboardOutputs;
  publicOutputs = complete.flake.cupboardPublicOutputs or [];
  publicOutputsWithoutSecrets = publicOnly.flake.cupboardPublicOutputs or [];
  lazyScheduling = {
    count = builtins.length lazyTargets;
    selected = map (target: target.attr) lazyTargets;
    checks = lib.mapAttrs (_:
      lib.mapAttrs (_: check: {
        isDerivation = lib.isDerivation check;
        runOnce = check.ci.runOnce or false;
        requiredFeatures = nixbuild.requiredFeatures check;
        drvPathFails = !(builtins.tryEval check.drvPath).success;
      }))
    lazyChecks;
  };
}
