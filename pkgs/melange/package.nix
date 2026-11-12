# To update: nix run .#update-melange
{
  buildGoLatestModule,
  upstreamPackage,
  updaters,
  lib,
}: let
  version = "0.64.1";
in
  assert lib.assertMsg (lib.versionOlder upstreamPackage.version version) "nixpkgs now provides Melange ${upstreamPackage.version}. Review whether the local version override is still needed.";
    (upstreamPackage.override {
      buildGoModule = buildGoLatestModule;
    }).overrideAttrs (_finalAttrs: prevAttrs: {
      inherit version;
      src = prevAttrs.src.overrideAttrs {outputHash = "sha256-p7QYUx39V/cNIoARvg/VYPccX6xA7OOOXnLTLgKrbFs=";};
      vendorHash = "sha256-oBc0PQyw8Fk5sQwzNErJmLpGS7a/NXMxRw3fomiwsVg=";

      passthru =
        (prevAttrs.passthru or {})
        // {
          maintenance = {
            source = "release";
            inputs = ["nixpkgs"];
            refresh = true;
          };
          updateScript = updaters.mkNixUpdateUpdater {
            refresh = true;
            attr = "melange";
            extraFlags = ["--use-github-releases"];
            unsetEnv = ["GITHUB_TOKEN"];
          };
        };
    })
