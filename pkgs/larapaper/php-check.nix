{
  inputs,
  lib,
  ...
}: {
  pkgs,
  system,
  ...
}:
(
  let
    stablePhp = inputs.nixpkgs-stable.legacyPackages.${system}.php84;
    selectPhp = version:
      (import ./args.nix {
        final = pkgs // {php84.version = "8.4.27";};
        inputs = {
          nixpkgs.legacyPackages.${system}.php84 = {inherit version;};
          nixpkgs-stable.legacyPackages.${system}.php84.version = "8.4.27";
        };
      }).php84;

    assertions = [
      {
        name = "LaraPaper uses PHP 8.4 from nixpkgs-stable";
        pass = pkgs.larapaper.php.unwrapped.drvPath == stablePhp.unwrapped.drvPath;
      }
      {
        name = "stable PHP is selected while unstable is vulnerable";
        pass =
          builtins.tryEval (selectPhp "8.4.26")
          == {
            success = true;
            value.version = "8.4.27";
          };
      }
      {
        name = "the override rejects fixed unstable versions";
        pass =
          map (version: builtins.tryEval (selectPhp version)) ["8.4.27" "8.4.28" "8.5.0"]
          == lib.replicate 3 {
            success = false;
            value = false;
          };
      }
    ];
    failures = lib.filter (assertion: !assertion.pass) assertions;
    report = lib.concatMapStringsSep "\n" (assertion: assertion.name) failures;
  in {
    checks.larapaper-php = pkgs.runCommandLocal "larapaper-php" {inherit report;} ''
      if [ -n "$report" ]; then printf '%s\n' "$report" >&2; exit 1; fi
      touch "$out"
    '';
  }
).checks
