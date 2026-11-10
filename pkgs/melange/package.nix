# To update: nix run .#update-melange
{
  buildGoLatestModule,
  upstreamPackage,
  updaters,
  lib,
}: let
  version = "0.64.0";
in
  assert lib.assertMsg (lib.versionOlder upstreamPackage.version version) "nixpkgs now provides Melange ${upstreamPackage.version}. Review whether the local version override is still needed.";
    (upstreamPackage.override {
      buildGoModule = buildGoLatestModule;
    }).overrideAttrs (_finalAttrs: prevAttrs: {
      inherit version;
      src = prevAttrs.src.overrideAttrs {outputHash = "sha256-NPiwmI5f0fMDt4ZKwBa2cxm1EkC1I8VvV8TbY+z3aCk=";};
      vendorHash = "sha256-23v+ewScSiL52VqaUQbARfQAdF7wged9wM9OXWBhFwo=";

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
