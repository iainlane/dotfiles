{
  upstreamPackage,
  nixDirenvSource,
  callPackage,
  lib,
}:
assert lib.assertMsg (!lib.versionOlder "3.2.0" upstreamPackage.version) "nix-direnv has advanced past 3.2.0. Remove the temporary source input and package override.";
  (callPackage nixDirenvSource {}).overrideAttrs (old: {
    passthru =
      (old.passthru or {})
      // {
        updateScript = null;
        maintenance = {
          source = "input";
          inputs = ["nix-direnv"];
          temporary = true;
          retirement = "Remove the temporary source when the packaged release includes the GC-root fix.";
        };
      };
  })
