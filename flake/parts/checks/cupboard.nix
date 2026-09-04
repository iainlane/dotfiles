# Compares the cupboard target set with a snapshot kept by hand. Adding or
# removing a host means editing the list below, and the check prints the
# difference so the edit is obvious.
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
      bestEffort = true;
      cohort = "aarch64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "aarch64-linux/generic-linux-ancaster";
      system = "aarch64-linux";
    }
    {
      attr = ".#deploy.nodes.bonington.profiles.system.path";
      bestEffort = true;
      cohort = "x86_64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/nixos-bonington";
      system = "x86_64-linux";
    }
    {
      attr = ".#deploy.nodes.cripps.profiles.system.path";
      bestEffort = true;
      cohort = "x86_64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/generic-linux-cripps";
      system = "x86_64-linux";
    }
    {
      attr = ".#deploy.nodes.florence.profiles.system.path";
      bestEffort = true;
      cohort = "x86_64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/generic-linux-florence";
      system = "x86_64-linux";
    }
    {
      attr = ".#deploy.nodes.melton.profiles.system.path";
      bestEffort = true;
      cohort = "aarch64-darwin";
      os = "macos-latest";
      remote = false;
      rootSuffix = "aarch64-darwin/darwin-melton";
      system = "aarch64-darwin";
    }
    {
      attr = ".#deploy.nodes.sherwood.profiles.system.path";
      bestEffort = true;
      cohort = "x86_64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/generic-linux-sherwood";
      system = "x86_64-linux";
    }
    {
      attr = ".#deploy.nodes.ancaster.profiles.${username}.path";
      bestEffort = true;
      cohort = "aarch64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "aarch64-linux/home-ancaster";
      system = "aarch64-linux";
    }
    {
      attr = ".#deploy.nodes.bonington.profiles.${username}.path";
      bestEffort = true;
      cohort = "x86_64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/home-bonington";
      system = "x86_64-linux";
    }
    {
      attr = ".#deploy.nodes.cripps.profiles.${username}.path";
      bestEffort = true;
      cohort = "x86_64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/home-cripps";
      system = "x86_64-linux";
    }
    {
      attr = ".#deploy.nodes.florence.profiles.${username}.path";
      bestEffort = true;
      cohort = "x86_64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/home-florence";
      system = "x86_64-linux";
    }
    {
      attr = ".#deploy.nodes.melton.profiles.${username}.path";
      bestEffort = true;
      cohort = "aarch64-darwin";
      os = "macos-latest";
      remote = false;
      rootSuffix = "aarch64-darwin/home-melton";
      system = "aarch64-darwin";
    }
    {
      attr = ".#deploy.nodes.sherwood.profiles.${username}.path";
      bestEffort = true;
      cohort = "x86_64-linux";
      os = "ubuntu-latest";
      remote = true;
      rootSuffix = "x86_64-linux/home-sherwood";
      system = "x86_64-linux";
    }
  ];

  targetSetCheckSystem = lib.head config.systems;
in {
  perSystem = {
    pkgs,
    system,
    ...
  }: {
    checks = lib.optionalAttrs (system == targetSetCheckSystem) {
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
