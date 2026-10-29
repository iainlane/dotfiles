# To update: nix run .#update-melange
{
  buildGoLatestModule,
  melange,
  updaters,
}:
(melange.override {
  buildGoModule = buildGoLatestModule;
}).overrideAttrs (_finalAttrs: prevAttrs: {
  version = "0.63.2";
  src = prevAttrs.src.overrideAttrs {outputHash = "sha256-e9hlevB6Ai/+z4ZN8KGBnPY6MWxYE1HPFA2DyiRM+Mw=";};
  vendorHash = "sha256-jGWIX3LWu8Gt9fkOtmKG/eXeCpclEnDMoyrlfQB8qKo=";

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
