{
  pkgs,
  lib,
  ...
}: let
  hosts = {
    linux = {
      hostname = "linux.example";
      system = "x86_64-linux";
    };
    darwin = {
      hostname = "darwin.example";
      system = "aarch64-darwin";
    };
  };
  hostResults =
    lib.mapAttrs (_: _host: {
      configuration = {};
      systemProfile = _: _: {path = pkgs.hello;};
      homeConfiguration.activationPackage = pkgs.hello;
      deployment.sshOpts = ["-p" "2222"];
    })
    hosts;
  fakeCheck = nodes: {
    type = "derivation";
    outputs = ["out"];
    outPath = "/nix/store/00000000000000000000000000000000-fixture";
    drvPath = "/nix/store/00000000000000000000000000000000-fixture.drv";
    name = builtins.unsafeDiscardStringContext (builtins.toJSON {
      names = lib.attrNames nodes;
      paths = lib.mapAttrs (_: node: lib.mapAttrs (_: profile: toString profile.path) node.profiles) nodes;
      contexts = lib.mapAttrs (_: node: lib.mapAttrs (_: profile: builtins.getContext "${profile.path}") node.profiles) nodes;
    });
  };
  deployLibFor = _: {
    activate.home-manager = home: home.activationPackage;
    deployChecks = {nodes}: {
      deploy-schema = fakeCheck nodes;
      deploy-activate = fakeCheck nodes;
    };
  };
  subject = import ./outputs.nix {
    inputs = {};
    inherit lib hosts hostResults deployLibFor;
    username = "fixture";
  };
  checks = system: subject.checks {inherit system;};
  schema = builtins.fromJSON (checks "aarch64-darwin").deploy-schema.name;
  native = system: builtins.fromJSON (checks system).deploy-activate.name;
  paths = {
    fixture = toString pkgs.hello;
    system = toString pkgs.hello;
  };
  contexts = {
    fixture = builtins.getContext "${pkgs.hello}";
    system = builtins.getContext "${pkgs.hello}";
  };
  checkPolicy = system: {
    schema = {
      inherit ((checks system).deploy-schema) ci requiredSystemFeatures;
    };
    activate = {
      inherit ((checks system).deploy-activate) requiredSystemFeatures;
    };
  };
  tools = import ./tools.nix {
    inherit lib;
    inputs.system-manager.packages.x86_64-linux.default = pkgs.hello;
    deployPackageFor = _: pkgs.hello;
  };
  toolsFor = system: {
    apps = lib.attrNames (tools.apps {inherit system;});
    packages = lib.attrNames (tools.packages {
      inherit system;
      pkgs.nh = pkgs.hello;
    });
  };
  actual = {
    nodes = subject.deploy.nodes;
    inherit schema;
    nativeLinux = native "x86_64-linux";
    nativeDarwin = native "aarch64-darwin";
    policy = lib.genAttrs ["aarch64-darwin" "x86_64-linux"] checkPolicy;
    tools = lib.genAttrs ["aarch64-darwin" "x86_64-linux"] toolsFor;
  };
  expected = {
    nodes =
      lib.mapAttrs (_: host: {
        inherit (host) hostname;
        sshUser = "fixture";
        sshOpts = ["-p" "2222"];
        profilesOrder = ["system" "fixture"];
        profiles = {
          system.path = pkgs.hello;
          fixture = {
            user = "fixture";
            path = pkgs.hello;
          };
        };
      })
      hosts;
    schema = {
      names = ["darwin" "linux"];
      paths = {
        darwin = paths;
        linux = paths;
      };
      contexts = lib.genAttrs ["darwin" "linux"] (_: {
        fixture = {};
        system = {};
      });
    };
    nativeLinux = {
      names = ["linux"];
      paths.linux = paths;
      contexts.linux = contexts;
    };
    nativeDarwin = {
      names = ["darwin"];
      paths.darwin = paths;
      contexts.darwin = contexts;
    };
    policy = lib.genAttrs ["aarch64-darwin" "x86_64-linux"] (_: {
      schema = {
        ci.runOnce = true;
        requiredSystemFeatures = [];
      };
      activate.requiredSystemFeatures = [];
    });
    tools = {
      aarch64-darwin = {
        apps = ["deploy-rs"];
        packages = ["deploy-rs" "nh"];
      };
      x86_64-linux = {
        apps = ["deploy-rs" "system-manager"];
        packages = ["deploy-rs" "nh"];
      };
    };
  };
in {
  deployment-contracts = assert lib.assertMsg (actual == expected) "Deployment profiles, check policy or operational tools differ from the expected configuration.";
    pkgs.runCommandLocal "deployment-contracts" {} "touch $out";
}
