{
  hosts,
  username,
  systems,
  checks,
  slowChecks,
  targets,
  lib,
  featureResolver,
  ...
}: let
  inherit (import ../../../lib/ci.nix) validationSystem;
  nixbuild = import ../../../lib/nixbuild.nix {inherit lib;};

  buildable = system: check:
    featureResolver.isDarwin (featureResolver.contextForSystem system) || nixbuild.canBuild system check;

  entry = attr: system: rootSuffix:
    lib.nameValuePair attr {inherit system rootSuffix;};

  profiles = lib.concatLists (lib.mapAttrsToList (hostname: host: [
      (entry ".#deploy.nodes.${hostname}.profiles.system.path" host.system "${host.system}/${host.os}-${hostname}")
      (entry ".#deploy.nodes.${hostname}.profiles.${username}.path" host.system "${host.system}/home-${hostname}")
    ])
    hosts);

  deployTools =
    map
    (system: entry ".#packages.${system}.deploy-rs" system "${system}/deploy-rs")
    (lib.unique (map (host: host.system) (lib.attrValues hosts)));

  validationEntry = attr: suffix:
    entry attr validationSystem "${validationSystem}/${suffix}";

  checkEntries = lib.concatLists (lib.mapAttrsToList
    (system: systemChecks:
      map
      (name: entry ".#checks.${system}.${name}" system "${system}/checks-${name}")
      (lib.attrNames (lib.filterAttrs (_: check: buildable system check && (!(check.ci.runOnce or false) || system == validationSystem)) systemChecks)))
    checks);

  slowCheckEntries =
    map
    (name: validationEntry ".#legacyPackages.${validationSystem}.slowChecks.${name}" "slow-checks-${name}")
    (lib.attrNames (lib.filterAttrs (_: buildable validationSystem) slowChecks));

  required = lib.listToAttrs (
    profiles
    ++ deployTools
    ++ [(validationEntry ".#packages.${validationSystem}.local-packages" "packages")]
    ++ checkEntries
    ++ slowCheckEntries
  );

  expected = {
    schema = {
      availableSystems = lib.sort builtins.lessThan systems;
      selectedSystems = [validationSystem];
    };
    coverage = lib.attrNames required;
    policy =
      lib.mapAttrs (_: target: {
        inherit (target) system rootSuffix;
        bestEffort = false;
        cohort = target.system;
        os =
          if featureResolver.isDarwin (featureResolver.contextForSystem target.system)
          then "macos-latest"
          else if featureResolver.isAarch64 (featureResolver.contextForSystem target.system)
          then "ubuntu-24.04-arm"
          else "ubuntu-latest";
        remote = !featureResolver.isDarwin (featureResolver.contextForSystem target.system);
      })
      required;
  };

  actual = {
    schema = {
      availableSystems = lib.sort builtins.lessThan (lib.filter (system: checks.${system} ? deploy-schema) systems);
      selectedSystems = map (target: target.system) (lib.filter (target: target.attr == ".#checks.${target.system}.deploy-schema") targets);
    };
    coverage = lib.sort builtins.lessThan (map (target: target.attr) targets);
    policy = lib.listToAttrs (map
      (target: lib.nameValuePair target.attr (removeAttrs target ["attr" "rootDrvPath"]))
      targets);
  };
in
  {pkgs, ...}: {
    checks.cupboard-targets =
      pkgs.runCommandLocal "cupboard-targets" {
        expected = builtins.toJSON expected;
        actual = builtins.toJSON actual;
        nativeBuildInputs = [pkgs.jq];
      }
      ''
        printf '%s' "$expected" >expected.json
        printf '%s' "$actual" >actual.json

        for check in coverage policy schema; do
          jq --sort-keys ".$check" expected.json >"$check.expected.json"
          jq --sort-keys ".$check" actual.json >"$check.actual.json"

          if ! diff --unified "$check.expected.json" "$check.actual.json"; then
            echo >&2
            echo "The cupboard targets fail the $check check in flake/cupboard/checks/targets.nix." >&2
            echo "Lines marked - are expected and missing; lines marked + are unexpected." >&2
            exit 1
          fi
        done

        touch "$out"
      '';
  }
