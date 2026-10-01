# To update: nix run .#update-melange
{
  buildGoLatestModule,
  melange,
  updaters,
}:
(melange.override {
  buildGoModule = buildGoLatestModule;
}).overrideAttrs (_finalAttrs: prevAttrs: {
  version = "0.61.2";
  src = prevAttrs.src.overrideAttrs {outputHash = "sha256-4U+wPzmQC+vM+MEdmQXE14+XnzMQq9uQxPji2r7wRLU=";};
  vendorHash = "sha256-zPGHUuh6LpYNY+yKWeKqD/OtlOoCumuUA9H60oAVxB0=";

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
