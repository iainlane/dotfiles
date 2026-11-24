{
  lib,
  runCommandLocal,
}: let
  selectedNode = regularVersion: stableVersion:
    (import ./args.nix {
      final = {};
      upstreamPackageSets = {
        nixpkgs = {
          inherit lib;
          nodejs_24.version = regularVersion;
        };
        nixpkgs-stable.nodejs_24.version = stableVersion;
      };
    }).nodejs.version;
in
  assert lib.assertMsg (selectedNode "24.22.0" "24.22.3" == "24.22.3")
  "REA must fall back to the stable package set if the regular package set provides an older Node version.";
  assert lib.assertMsg (selectedNode "24.22.1" "24.22.3" == "24.22.1")
  "REA must use the regular package set when it provides a supported Node version.";
  assert lib.assertMsg (!(builtins.tryEval (selectedNode "24.21.0" "24.22.0")).success)
  "REA must reject Node versions below its minimum.";
    runCommandLocal "rea-upstream-version" {} ''
      touch "$out"
    ''
