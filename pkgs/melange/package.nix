# To update: nix run .#update-melange
{
  buildGoLatestModule,
  melange,
  updaters,
}:
(melange.override {
  buildGoModule = buildGoLatestModule;
}).overrideAttrs (_finalAttrs: prevAttrs: {
  version = "0.62.0";
  src = prevAttrs.src.overrideAttrs {outputHash = "sha256-ScKfpJ8+NKhxvNZYQrYFQWoD4tjgZ+XAEqTJ14r9ZzA=";};
  vendorHash = "sha256-R2fxo5Dcjn0dvk7xnAUvBazJmtXC8PKngY1iysxJFdI=";

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
