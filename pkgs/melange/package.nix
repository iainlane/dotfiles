# To update: nix run .#update-melange
{
  buildGoLatestModule,
  melange,
  updaters,
}:
(melange.override {
  buildGoModule = buildGoLatestModule;
}).overrideAttrs (_finalAttrs: prevAttrs: {
  version = "0.62.1";
  src = prevAttrs.src.overrideAttrs {outputHash = "sha256-v0PpsesBoeJiHtDLyadGmt9qj0oO2CeiLimWvJ1a9X0=";};
  vendorHash = "sha256-c5YONjf/I9LM5yXFdUwxR+R41Tfu8mm7Sm6yBuPHchU=";

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
