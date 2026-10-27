{
  lib,
  systems,
  inputs,
}: let
  inherit (import ../lib/ci.nix) validationSystem;
  fakePackage = name: {
    drvPath = "/nix/store/00000000000000000000000000000000-${name}.drv";
  };
  fixtureConfig.dotfiles = {
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
  };
  fixtureConfig.flake = {
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
        deploy-activate = fakePackage "activate";
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
    import ../flake/cupboard/targets.nix {
      inherit lib config;
      featureResolver = import ../lib/features.nix {inherit lib;};
    };
  complete = subject fixtureConfig;
  publicOnly = subject {
    inherit (fixtureConfig) dotfiles;
    flake =
      fixtureConfig.flake
      // {
        deploy = throw "Private deploy profiles were evaluated.";
        checks = lib.mapAttrs (_: checks:
          checks
          // {
            deploy-activate = throw "A private activation check was evaluated.";
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
    config.dotfiles = {
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
      (import ../flake/host-assembly/checks/evaluation.nix {
        inherit lib hostResults;
        hostMetadata = throw "Public scheduling forced host metadata.";
        inherit (config.dotfiles) hosts username;
      }) {
        inherit system;
        pkgs = {inherit runCommandLocal;};
      };
    deployChecks = (import ../flake/deployment/checks.nix {
      inherit inputs lib;
      hosts = config.dotfiles.hosts;
      nodes = throw "The deploy nodes were forced.";
    }) {inherit system;};
    managedChecks =
      import ../features/hermes/managed-config-host-check.nix {
        hostConfig.name = "fixture";
        systemConfig = hostResults;
      } {
        inherit lib;
        pkgs = {inherit runCommandLocal;};
      };
  in
    hostChecks // deployChecks // managedChecks;
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
      inherit (fixtureConfig) dotfiles;
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
