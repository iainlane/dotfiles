# To update: nix run .#update-melange
{
  buildGoLatestModule,
  melange,
  updaters,
}:
(melange.override {
  buildGoModule = buildGoLatestModule;
}).overrideAttrs (_finalAttrs: prevAttrs: {
  version = "0.63.0";
  src = prevAttrs.src.overrideAttrs {outputHash = "sha256-CssVOdkSzIY/9oflvFHX3yOP+9ognzEHoREVe34V/Dw=";};
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
