# To update: nix run .#update-melange
{
  buildGoLatestModule,
  melange,
  updaters,
}:
(melange.override {
  buildGoModule = buildGoLatestModule;
}).overrideAttrs (_finalAttrs: prevAttrs: {
  version = "0.61.1";
  src = prevAttrs.src.overrideAttrs {outputHash = "sha256-2p4LhaqAT3O2/C9QgDCeiPK8asnV/6GpHqs+zpe5v80=";};
  vendorHash = "sha256-878bxIrAYh2GTo+iEuF0iLe+B3NNE6lbDP33Qq6Oxac=";

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
