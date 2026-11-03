{
  lib,
  rea,
  runCommandLocal,
}: let
  dependencySource = {
    inherit (rea.npmDeps) src;
    patches = rea.npmDeps.patches or [];
  };
in
  assert lib.assertMsg (dependencySource
    == {
      inherit (rea) src;
      patches = [];
    })
  "REA's npm dependency fetch must not depend on source patches.";
    runCommandLocal "rea-npm-deps-policy" {} ''
      touch "$out"
    ''
