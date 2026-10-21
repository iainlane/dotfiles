{
  lib,
  systems,
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
        claude-prompt-conformance.tests =
          lib.genAttrs [
            "claudeEndpoint"
            "codexEndpoint"
            "codexProtocol"
            "fixtureEnvironments"
            "python"
          ]
          fakePackage;
      };
    };
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
in {
  inherit validationSystem;
  checkSystems = lib.attrNames fixtureConfig.flake.checks;
  outputs = complete.flake.cupboardOutputs;
  publicOutputs = complete.flake.cupboardPublicOutputs or [];
  publicOutputsWithoutSecrets = publicOnly.flake.cupboardPublicOutputs or [];
}
