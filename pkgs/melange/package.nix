# To update: nix run .#update-melange
{
  melange,
  updaters,
}:
melange.overrideAttrs (_finalAttrs: prevAttrs: {
  version = "0.57.0";
  src = prevAttrs.src.overrideAttrs {outputHash = "sha256-3+UXZpeC/WdrKpF3P+qV9k+oipZ9OWpOCfK8nZ0PAVc=";};
  vendorHash = "sha256-cyhegU/jGLVRidAEAq2XY9agjmMr28u7Hf9cZ67um1g=";

  passthru =
    (prevAttrs.passthru or {})
    // {
      updateScript = updaters.mkNixUpdateUpdater {
        attr = "melange";
        extraFlags = ["--use-github-releases"];
      };
    };
})
