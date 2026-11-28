# To update: nix run .#update-melange
{
  buildGoLatestModule,
  upstreamPackage,
  updaters,
  lib,
}: let
  version = "0.66.0";
in
  assert lib.assertMsg (lib.versionOlder upstreamPackage.version version) "nixpkgs now provides Melange ${upstreamPackage.version}. Review whether the local version override is still needed.";
    (upstreamPackage.override {
      buildGoModule = buildGoLatestModule;
    }).overrideAttrs (_finalAttrs: prevAttrs: {
      inherit version;
      src = prevAttrs.src.overrideAttrs {outputHash = "sha256-f4C037cdEdpc9SX2ZpczpErdfgmcOSd0Vf6zr7nqtfw=";};
      vendorHash = "sha256-sz72TwdkTiMl5LOusXTgSd6UV+cheNt/6CSVy4lyOQs=";

      passthru =
        (prevAttrs.passthru or {})
        // {
          maintenance = {
            source = "release";
            inputs = ["nixpkgs"];
            refresh = true;
            refreshInputs = [];
          };
          updateScript = updaters.mkNixUpdateUpdater {
            refresh = true;
            attr = "melange";
            extraFlags = ["--use-github-releases"];
            unsetEnv = ["GITHUB_TOKEN"];
          };
        };
    })
