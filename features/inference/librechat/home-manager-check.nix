{
  features,
  featureResolver,
  modelCatalog,
}: {
  inputs,
  lib,
  pkgs,
  system,
  flakeContext,
  flakeContexts,
  ...
}: let
  mkAssertionCheck = import ../../../lib/assertion-check.nix {inherit lib pkgs;};
  inherit (import ../../../lib/home.nix {inherit inputs lib featureResolver;}) mkHomeConfiguration;
  mcp = flakeContext.mcpByChannel.unstable;

  hostConfig = {
    name = "librechat-fixture";
    arch = pkgs.stdenv.hostPlatform.parsed.cpu.name;
    os =
      if pkgs.stdenv.hostPlatform.isDarwin
      then "darwin"
      else "generic-linux";
    inherit system;
    homeDirectory = "/home/fixture";
    features = [features.inference.librechat];
    excludes = [];
  };

  makeHome = extra:
    mkHomeConfiguration {
      homeManager = inputs.home-manager;
      inherit pkgs;
      extraSpecialArgs =
        {
          inherit inputs hostConfig modelCatalog flakeContext flakeContexts mcp;
          defaultModels = modelCatalog.defaults;
          pkgs-unstable = pkgs;
        }
        // (extra.specialArgs or {});
      modules =
        featureResolver.resolveFeatures {
          class = "homeManager";
          inherit hostConfig;
        }
        ++ [
          inputs.sops-nix.homeManagerModules.sops
          {
            home = {
              username = "fixture";
              inherit (hostConfig) homeDirectory;
              stateVersion = "26.05";
            };
          }
        ]
        ++ (extra.modules or []);
    };

  home = makeHome {};

  unusedGuest = {
    image = "/unused/image";
    kernel = "/unused/kernel";
    initrd = "/unused/initrd";
    init = "/unused/init";
  };

  bundleHome = excludeBundles: (makeHome {
    specialArgs.librechatGuest = unusedGuest;
    modules = [
      {
        dotfiles.ai.bundles.fixture = {
          mcpServers.fixture-server.command = "/fixture/bin/server";
          skills.fixture-skill.skill = {
            frontmatter.description = "Fixture skill.";
            body = "Fixture skill.\n";
          };
        };
        dotfiles.inference.librechat.excludeBundles = excludeBundles;
      }
    ];
  });

  excludedBundle = (bundleHome ["fixture"]).config;

  excludedManifest = excludedBundle.dotfiles.inference.librechat.manifest.value;

  startupHome = makeHome {
    specialArgs.librechatGuest = unusedGuest;
    modules = [
      {
        dotfiles.ai = {
          mcpServers = lib.mkForce {
            oauth-fixture = {
              url = "https://oauth.fixture.invalid/mcp";
              startup = false;
              requiresOAuth = true;
            };
          };
          skills = lib.mkForce {};
        };
        dotfiles.inference.librechat = {
          ollamaUrl = null;
          anthropicKeyFile = toString (pkgs.writeText "librechat-fixture-anthropic-key" "fixture-key");
          openaiKeyFile = null;
          openrouterKeyFile = null;
        };
      }
    ];
  };

  darwin = pkgs.stdenv.hostPlatform.isDarwin;
  python = pkgs.python3.withPackages (packages: [packages.pydantic packages.pymongo packages.structlog]);
  agent = startupHome.config.launchd.agents.librechat.config;
  service = startupHome.config.systemd.user.services.librechat.Service;
  workingDirectory =
    if darwin
    then agent.WorkingDirectory
    else service.WorkingDirectory or null;
  startupConfiguration = pkgs.writeText "librechat-startup.json" (builtins.toJSON {
    manifest = toString startupHome.config.dotfiles.inference.librechat.manifest;
    runtime = lib.getExe pkgs.librechat-runtime;
    fixtureCommand = [
      (lib.getExe pkgs.nodejs_24)
      "${pkgs.librechat.src}/e2e/setup/mcp-nonblocking.mjs"
    ];
    fixturePackageRoot = "${pkgs.librechat}/lib/node_modules/LibreChat";
    command =
      if darwin
      then agent.ProgramArguments
      else service.ExecStart;
    environment =
      if darwin
      then
        {PATH = "/usr/bin:/bin:/usr/sbin:/sbin";}
        // (
          if agent.EnvironmentVariables == null
          then {}
          else agent.EnvironmentVariables
        )
      else service.Environment or [];
    workingDirectory =
      if workingDirectory != null
      then workingDirectory
      else if darwin
      then "/"
      else startupHome.config.home.homeDirectory;
  });

  actual = {
    manifest = builtins.isString home.config.dotfiles.inference.librechat.manifest.drvPath;
    archive = home.config.dotfiles.agentsview.dataDir;
    models = home.config.dotfiles.inference.ollama.models;
  };

  expected = {
    manifest = true;
    archive = "/home/fixture/.agentsview";
    models = map (name: {
      inherit name;
      aliases = [];
      parameters = {};
    }) ["qwen3:4b" "qwen3-embedding:0.6b"];
  };
in {
  librechat-startup =
    if darwin
    then
      pkgs.runCommand "librechat-startup" {
        nativeBuildInputs = [python];
        __darwinAllowLocalNetworking = true;
      } ''
        python3 ${./startup-test.py} ${startupConfiguration}
        touch "$out"
      ''
    else
      # MongoDB's allocator needs sysfs. A plain Linux build sandbox omits sysfs.
      pkgs.testers.runNixOSTest {
        name = "librechat-startup";
        nodes.machine = {lib, ...}: {
          networking.useDHCP = false;
          users.users.fixture = {
            isNormalUser = true;
            uid = 1000;
          };
          virtualisation = {
            memorySize = 4096;
            cores = 2;
            vlans = lib.mkForce [];
            qemu.networkingOptions = lib.mkForce ["-nic none"];
          };
        };
        testScript = ''
          from datetime import timedelta

          machine.start()
          machine.wait_for_unit("multi-user.target")
          machine.succeed("su - fixture -c '${python}/bin/python3 ${./startup-test.py} ${startupConfiguration}'", timeout=timedelta(seconds=400))
        '';
      };

  librechat-home-manager = mkAssertionCheck {
    name = "librechat-home-manager";
    assertions = [
      {
        assertion = actual == expected;
        message = "LibreChat must evaluate without selecting the AgentsView or Ollama service features.";
      }
    ];
  };

  librechat-bundle-exclusion = let
    actual = {
      shared = {
        server = excludedBundle.dotfiles.ai.mcpServers ? fixture-server;
        skill = excludedBundle.dotfiles.ai.skills ? fixture-skill;
      };
      librechat.server = lib.elem "fixture-server" excludedManifest.localMcpServers;
      unknownBundleRejected = !(builtins.tryEval (bundleHome ["missing"]).config.home.username).success;
    };

    expected = {
      shared = {
        server = true;
        skill = true;
      };
      librechat.server = false;
      unknownBundleRejected = true;
    };
  in
    mkAssertionCheck {
      name = "librechat-bundle-exclusion";
      assertions = [
        {
          assertion = actual == expected;
          message = "LibreChat must leave out every MCP server and skill of an excluded bundle, and the shared registries must keep them.";
        }
      ];
      script = ''
        test -e ${excludedManifest.skillsDirectory}/plain-technical-prose
        test ! -e ${excludedManifest.skillsDirectory}/fixture-skill
        touch "$out"
      '';
    };
}
