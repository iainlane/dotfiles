{
  config,
  lib,
  ...
}: let
  inherit (config.flake) username;

  targets = config.flake.cupboardOutputs;
  targetShape = target: removeAttrs target ["rootDrvPath"];
  sortTargets = lib.sortOn (target: target.attr);

  actual = sortTargets (map targetShape targets);
  expected = sortTargets [
    {
      attr = ".#deploy.nodes.ancaster.profiles.system.path";
      bestEffort = false;
      cohort = "aarch64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "aarch64-linux/generic-linux-ancaster";
      system = "aarch64-linux";
    }
    {
      attr = ".#deploy.nodes.bonington.profiles.system.path";
      bestEffort = false;
      cohort = "x86_64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/nixos-bonington";
      system = "x86_64-linux";
    }
    {
      attr = ".#deploy.nodes.cripps.profiles.system.path";
      bestEffort = false;
      cohort = "x86_64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/generic-linux-cripps";
      system = "x86_64-linux";
    }
    {
      attr = ".#deploy.nodes.florence.profiles.system.path";
      bestEffort = false;
      cohort = "x86_64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/generic-linux-florence";
      system = "x86_64-linux";
    }
    {
      attr = ".#deploy.nodes.melton.profiles.system.path";
      bestEffort = false;
      cohort = "aarch64-darwin";
      os = "macos-latest";
      remote = false;
      rootSuffix = "aarch64-darwin/darwin-melton";
      system = "aarch64-darwin";
    }
    {
      attr = ".#deploy.nodes.sherwood.profiles.system.path";
      bestEffort = false;
      cohort = "x86_64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/generic-linux-sherwood";
      system = "x86_64-linux";
    }
    {
      attr = ".#deploy.nodes.ancaster.profiles.${username}.path";
      bestEffort = false;
      cohort = "aarch64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "aarch64-linux/home-ancaster";
      system = "aarch64-linux";
    }
    {
      attr = ".#deploy.nodes.bonington.profiles.${username}.path";
      bestEffort = false;
      cohort = "x86_64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/home-bonington";
      system = "x86_64-linux";
    }
    {
      attr = ".#deploy.nodes.cripps.profiles.${username}.path";
      bestEffort = false;
      cohort = "x86_64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/home-cripps";
      system = "x86_64-linux";
    }
    {
      attr = ".#deploy.nodes.florence.profiles.${username}.path";
      bestEffort = false;
      cohort = "x86_64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/home-florence";
      system = "x86_64-linux";
    }
    {
      attr = ".#deploy.nodes.melton.profiles.${username}.path";
      bestEffort = false;
      cohort = "aarch64-darwin";
      os = "macos-latest";
      remote = false;
      rootSuffix = "aarch64-darwin/home-melton";
      system = "aarch64-darwin";
    }
    {
      attr = ".#deploy.nodes.sherwood.profiles.${username}.path";
      bestEffort = false;
      cohort = "x86_64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/home-sherwood";
      system = "x86_64-linux";
    }
    {
      attr = ".#packages.x86_64-linux.local-packages";
      bestEffort = false;
      cohort = "x86_64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/packages";
      system = "x86_64-linux";
    }
    {
      attr = ".#checks.x86_64-linux.agentsview-secrets";
      bestEffort = false;
      cohort = "x86_64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/checks-agentsview-secrets";
      system = "x86_64-linux";
    }
    {
      attr = ".#checks.x86_64-linux.claude-managed-settings-layout";
      bestEffort = false;
      cohort = "x86_64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/checks-claude-managed-settings-layout";
      system = "x86_64-linux";
    }
    {
      attr = ".#checks.x86_64-linux.cupboard-targets";
      bestEffort = false;
      cohort = "x86_64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/checks-cupboard-targets";
      system = "x86_64-linux";
    }
    {
      attr = ".#checks.x86_64-linux.cupboard-workflows";
      bestEffort = false;
      cohort = "x86_64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/checks-cupboard-workflows";
      system = "x86_64-linux";
    }
    {
      attr = ".#checks.x86_64-linux.deploy-activate";
      bestEffort = false;
      cohort = "x86_64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/checks-deploy-activate";
      system = "x86_64-linux";
    }
    {
      attr = ".#checks.x86_64-linux.deploy-schema";
      bestEffort = false;
      cohort = "x86_64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/checks-deploy-schema";
      system = "x86_64-linux";
    }
    {
      attr = ".#checks.x86_64-linux.feature-registration";
      bestEffort = false;
      cohort = "x86_64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/checks-feature-registration";
      system = "x86_64-linux";
    }
    {
      attr = ".#checks.x86_64-linux.feature-resolution";
      bestEffort = false;
      cohort = "x86_64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/checks-feature-resolution";
      system = "x86_64-linux";
    }
    {
      attr = ".#checks.x86_64-linux.flake-input-updater";
      bestEffort = false;
      cohort = "x86_64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/checks-flake-input-updater";
      system = "x86_64-linux";
    }
    {
      attr = ".#checks.x86_64-linux.hermes-inbox-backup";
      bestEffort = false;
      cohort = "x86_64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/checks-hermes-inbox-backup";
      system = "x86_64-linux";
    }
    {
      attr = ".#checks.x86_64-linux.hermes-python-overrides";
      bestEffort = false;
      cohort = "x86_64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/checks-hermes-python-overrides";
      system = "x86_64-linux";
    }
    {
      attr = ".#checks.x86_64-linux.host-evaluation-generic-linux-cripps";
      bestEffort = false;
      cohort = "x86_64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/checks-host-evaluation-generic-linux-cripps";
      system = "x86_64-linux";
    }
    {
      attr = ".#checks.x86_64-linux.host-evaluation-generic-linux-florence";
      bestEffort = false;
      cohort = "x86_64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/checks-host-evaluation-generic-linux-florence";
      system = "x86_64-linux";
    }
    {
      attr = ".#checks.x86_64-linux.host-evaluation-generic-linux-sherwood";
      bestEffort = false;
      cohort = "x86_64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/checks-host-evaluation-generic-linux-sherwood";
      system = "x86_64-linux";
    }
    {
      attr = ".#checks.x86_64-linux.host-evaluation-home-bonington";
      bestEffort = false;
      cohort = "x86_64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/checks-host-evaluation-home-bonington";
      system = "x86_64-linux";
    }
    {
      attr = ".#checks.x86_64-linux.host-evaluation-home-cripps";
      bestEffort = false;
      cohort = "x86_64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/checks-host-evaluation-home-cripps";
      system = "x86_64-linux";
    }
    {
      attr = ".#checks.x86_64-linux.host-evaluation-home-florence";
      bestEffort = false;
      cohort = "x86_64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/checks-host-evaluation-home-florence";
      system = "x86_64-linux";
    }
    {
      attr = ".#checks.x86_64-linux.host-evaluation-home-sherwood";
      bestEffort = false;
      cohort = "x86_64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/checks-host-evaluation-home-sherwood";
      system = "x86_64-linux";
    }
    {
      attr = ".#checks.x86_64-linux.host-evaluation-nixos-bonington";
      bestEffort = false;
      cohort = "x86_64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/checks-host-evaluation-nixos-bonington";
      system = "x86_64-linux";
    }
    {
      attr = ".#checks.x86_64-linux.larapaper";
      bestEffort = false;
      cohort = "x86_64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/checks-larapaper";
      system = "x86_64-linux";
    }
    {
      attr = ".#checks.x86_64-linux.larapaper-updater";
      bestEffort = false;
      cohort = "x86_64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/checks-larapaper-updater";
      system = "x86_64-linux";
    }
    {
      attr = ".#checks.x86_64-linux.larapaper-web-library-updater";
      bestEffort = false;
      cohort = "x86_64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/checks-larapaper-web-library-updater";
      system = "x86_64-linux";
    }
    {
      attr = ".#checks.x86_64-linux.nix-retry";
      bestEffort = false;
      cohort = "x86_64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/checks-nix-retry";
      system = "x86_64-linux";
    }
    {
      attr = ".#checks.x86_64-linux.package-updater-coverage";
      bestEffort = false;
      cohort = "x86_64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/checks-package-updater-coverage";
      system = "x86_64-linux";
    }
    {
      attr = ".#checks.x86_64-linux.package-updater-versions";
      bestEffort = false;
      cohort = "x86_64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/checks-package-updater-versions";
      system = "x86_64-linux";
    }
    {
      attr = ".#checks.x86_64-linux.parakeet-tdt-onnx-updater";
      bestEffort = false;
      cohort = "x86_64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/checks-parakeet-tdt-onnx-updater";
      system = "x86_64-linux";
    }
    {
      attr = ".#checks.x86_64-linux.pi-lens-lua";
      bestEffort = false;
      cohort = "x86_64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/checks-pi-lens-lua";
      system = "x86_64-linux";
    }
    {
      attr = ".#checks.x86_64-linux.pi-startup";
      bestEffort = false;
      cohort = "x86_64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/checks-pi-startup";
      system = "x86_64-linux";
    }
    {
      attr = ".#checks.x86_64-linux.podman-image-absent";
      bestEffort = false;
      cohort = "x86_64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/checks-podman-image-absent";
      system = "x86_64-linux";
    }
    {
      attr = ".#checks.x86_64-linux.prompt-conformance-configuration";
      bestEffort = false;
      cohort = "x86_64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/checks-prompt-conformance-configuration";
      system = "x86_64-linux";
    }
    {
      attr = ".#checks.x86_64-linux.prose-lint-configuration";
      bestEffort = false;
      cohort = "x86_64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/checks-prose-lint-configuration";
      system = "x86_64-linux";
    }
    {
      attr = ".#checks.x86_64-linux.prose-lint-fixtures";
      bestEffort = false;
      cohort = "x86_64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/checks-prose-lint-fixtures";
      system = "x86_64-linux";
    }
    {
      attr = ".#checks.x86_64-linux.prose-lint-python";
      bestEffort = false;
      cohort = "x86_64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/checks-prose-lint-python";
      system = "x86_64-linux";
    }
    {
      attr = ".#checks.x86_64-linux.quadlet-contracts";
      bestEffort = false;
      cohort = "x86_64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/checks-quadlet-contracts";
      system = "x86_64-linux";
    }
    {
      attr = ".#checks.x86_64-linux.r2-backup";
      bestEffort = false;
      cohort = "x86_64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/checks-r2-backup";
      system = "x86_64-linux";
    }
    {
      attr = ".#checks.x86_64-linux.r2-verify";
      bestEffort = false;
      cohort = "x86_64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/checks-r2-verify";
      system = "x86_64-linux";
    }
    {
      attr = ".#checks.x86_64-linux.statix";
      bestEffort = false;
      cohort = "x86_64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/checks-statix";
      system = "x86_64-linux";
    }
    {
      attr = ".#checks.x86_64-linux.teamclaude";
      bestEffort = false;
      cohort = "x86_64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/checks-teamclaude";
      system = "x86_64-linux";
    }
    {
      attr = ".#checks.x86_64-linux.treefmt";
      bestEffort = false;
      cohort = "x86_64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/checks-treefmt";
      system = "x86_64-linux";
    }
    {
      attr = ".#checks.x86_64-linux.trmnl-framework-updater";
      bestEffort = false;
      cohort = "x86_64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/checks-trmnl-framework-updater";
      system = "x86_64-linux";
    }
    {
      attr = ".#checks.x86_64-linux.trmnl-liquid-cli-updater";
      bestEffort = false;
      cohort = "x86_64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/checks-trmnl-liquid-cli-updater";
      system = "x86_64-linux";
    }
    {
      attr = ".#checks.x86_64-linux.unifi-backup";
      bestEffort = false;
      cohort = "x86_64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/checks-unifi-backup";
      system = "x86_64-linux";
    }
    {
      attr = ".#packages.x86_64-linux.claude-prompt-conformance.tests.claudeEndpoint";
      bestEffort = false;
      cohort = "x86_64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/prompt-conformance-claudeEndpoint";
      system = "x86_64-linux";
    }
    {
      attr = ".#packages.x86_64-linux.claude-prompt-conformance.tests.codexEndpoint";
      bestEffort = false;
      cohort = "x86_64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/prompt-conformance-codexEndpoint";
      system = "x86_64-linux";
    }
    {
      attr = ".#packages.x86_64-linux.claude-prompt-conformance.tests.codexProtocol";
      bestEffort = false;
      cohort = "x86_64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/prompt-conformance-codexProtocol";
      system = "x86_64-linux";
    }
    {
      attr = ".#packages.x86_64-linux.claude-prompt-conformance.tests.fixtureEnvironments";
      bestEffort = false;
      cohort = "x86_64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/prompt-conformance-fixtureEnvironments";
      system = "x86_64-linux";
    }
    {
      attr = ".#packages.x86_64-linux.claude-prompt-conformance.tests.python";
      bestEffort = false;
      cohort = "x86_64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/prompt-conformance-python";
      system = "x86_64-linux";
    }
  ];
in {
  perSystem = {pkgs, ...}: {
    checks = {
      cupboard-targets =
        pkgs.runCommandLocal "cupboard-targets" {
          expected = builtins.toJSON expected;
          actual = builtins.toJSON actual;
          nativeBuildInputs = [pkgs.jq];
        }
        ''
          printf '%s' "$expected" | jq --sort-keys . >expected.json
          printf '%s' "$actual" | jq --sort-keys . >actual.json

          if ! diff --unified expected.json actual.json; then
            echo >&2
            echo "The cupboard targets differ from the list in flake/parts/checks/cupboard.nix." >&2
            echo "Lines marked - are expected and missing; lines marked + are new." >&2
            exit 1
          fi

          touch "$out"
        '';
    };
  };
}
