# To update: nix run .#update-melange
{
  buildGoLatestModule,
  melange,
  updaters,
}:
(melange.override {
  buildGoModule = buildGoLatestModule;
}).overrideAttrs (_finalAttrs: prevAttrs: {
  version = "0.64.0";
  src = prevAttrs.src.overrideAttrs {outputHash = "sha256-NPiwmI5f0fMDt4ZKwBa2cxm1EkC1I8VvV8TbY+z3aCk=";};
  vendorHash = "sha256-23v+ewScSiL52VqaUQbARfQAdF7wged9wM9OXWBhFwo=";

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
