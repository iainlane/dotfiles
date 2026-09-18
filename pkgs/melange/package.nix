# To update: nix run .#update-melange
{
  buildGoLatestModule,
  melange,
  updaters,
}:
(melange.override {
  buildGoModule = buildGoLatestModule;
}).overrideAttrs (_finalAttrs: prevAttrs: {
  version = "0.61.0";
  src = prevAttrs.src.overrideAttrs {outputHash = "sha256-SxoTEsKjgicTCpb3Eru808uLeQLA+Qcphrl6bcYcSIc=";};
  vendorHash = "sha256-8zAhmgj36CSO1B/vTfwwkXFWD1VV8FiVYlliaB5ff7s=";

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
