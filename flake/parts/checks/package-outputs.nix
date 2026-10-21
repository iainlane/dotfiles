{lib, ...}: let
  packageOutputs = import ../../../lib/package-outputs.nix {inherit lib;};
  throws = value: !(builtins.tryEval (builtins.deepSeq value true)).success;
  platform = lib.systems.elaborate "x86_64-linux";

  fake = name: platforms: {
    inherit name;
    meta = lib.optionalAttrs (platforms != null) {inherit platforms;};
  };
  updater = fake "tool-updater" null;
  suite = fake "tool-suite" null;
  tool =
    fake "tool" null
    // {
      passthru = {
        tests = {
          inherit updater;
          vm = fake "tool-vm" ["aarch64-linux"];
        };
        slowTests = {inherit suite;};
      };
    };
  plain = fake "plain" null;
  unavailable =
    fake "unavailable" ["aarch64-darwin"]
    // {
      passthru.tests.updater = fake "unavailable-updater" null;
    };
in {
  perSystem = {pkgs, ...}: let
    assertions = [
      {
        name = "available packages route their available tests";
        pass =
          packageOutputs.forPlatform platform {inherit tool plain unavailable;}
          == {
            packages = {inherit tool plain;};
            checks.tool-updater = updater;
            slowChecks.tool-suite = suite;
          };
      }
      {
        name = "colliding test names fail";
        pass =
          throws
          (packageOutputs.forPlatform platform {
            a.passthru.tests.b-c = fake "first" null;
            a-b.passthru.tests.c = fake "second" null;
          })
          .checks;
      }
    ];
    failures = lib.filter (assertion: !assertion.pass) assertions;
    report = lib.concatMapStringsSep "\n" (assertion: assertion.name) failures;
  in {
    checks.package-outputs = pkgs.runCommandLocal "package-outputs" {inherit report;} ''
      if [ -n "$report" ]; then printf '%s\n' "$report" >&2; exit 1; fi
      touch "$out"
    '';
  };
}
