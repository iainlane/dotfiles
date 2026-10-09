{lib}: let
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
    packages.x86_64-linux.local-packages = fakePackage "packages";
    checks.x86_64-linux = {
      deploy-schema = fakePackage "deploy";
      example = fakePackage "example";
      host-evaluation-home-test = fakePackage "host";
      prompt-conformance-configuration = fakePackage "configuration";
    };
    packages.x86_64-linux.claude-prompt-conformance.tests =
      lib.genAttrs [
        "claudeEndpoint"
        "codexEndpoint"
        "codexProtocol"
        "fixtureEnvironments"
        "python"
      ]
      fakePackage;
  };
  subject = config: import ../flake/parts/cupboard.nix {inherit lib config;};
  complete = subject fixtureConfig;
  publicOnly = subject {
    flake =
      fixtureConfig.flake
      // {
        deploy = throw "Private deploy profiles were evaluated.";
        checks.x86_64-linux =
          fixtureConfig.flake.checks.x86_64-linux
          // {
            deploy-schema = throw "A private deploy check was evaluated.";
            host-evaluation-home-test = throw "A private host check was evaluated.";
          };
      };
  };
in {
  outputs = complete.flake.cupboardOutputs;
  publicOutputs = complete.flake.cupboardPublicOutputs or [];
  publicOutputsWithoutSecrets = publicOnly.flake.cupboardPublicOutputs or [];
}
