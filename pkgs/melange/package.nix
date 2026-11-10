# To update: nix run .#update-melange
{
  buildGoLatestModule,
  melange,
  updaters,
}:
(melange.override {
  buildGoModule = buildGoLatestModule;
}).overrideAttrs (_finalAttrs: prevAttrs: {
  version = "0.64.1";
  src = prevAttrs.src.overrideAttrs {outputHash = "sha256-p7QYUx39V/cNIoARvg/VYPccX6xA7OOOXnLTLgKrbFs=";};
  vendorHash = "sha256-oBc0PQyw8Fk5sQwzNErJmLpGS7a/NXMxRw3fomiwsVg=";

  passthru =
    (prevAttrs.passthru or {})
    // {
      updateScript = updaters.mkNixUpdateUpdater {
        attr = "melange";
        extraFlags = ["--use-github-releases"];
        unsetEnv = ["GITHUB_TOKEN"];
      };
    };
})
