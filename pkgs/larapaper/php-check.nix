{lib, ...}: {
  pkgs,
  system,
  ...
}:
(
  let
    selectPhp = version:
      (import ./args.nix {
        final =
          pkgs
          // {
            php84 = {
              inherit version;
              source = "host";
            };
          };
        inputs = {
          nixpkgs-stable.legacyPackages.${system}.php84 = {
            version = "8.4.27";
            source = "stable";
          };
        };
      }).php84;

    assertions = [
      {
        name = "LaraPaper uses PHP with the security fixes";
        pass = lib.versionAtLeast pkgs.larapaper.php.version "8.4.27";
      }
      {
        name = "stable PHP is selected while the host's PHP is vulnerable";
        pass =
          builtins.tryEval (selectPhp "8.4.26")
          == {
            success = true;
            value = {
              version = "8.4.27";
              source = "stable";
            };
          };
      }
      {
        name = "the host's PHP is used once fixed";
        pass =
          map (version: builtins.tryEval (selectPhp version)) ["8.4.27" "8.4.28" "8.5.0"]
          == map (version: {
            success = true;
            value = {
              inherit version;
              source = "host";
            };
          }) ["8.4.27" "8.4.28" "8.5.0"];
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
