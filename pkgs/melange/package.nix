# To update: nix run .#update-melange
{
  melange,
  updaters,
}:
melange.overrideAttrs (_finalAttrs: prevAttrs: {
  version = "0.58.0";
  src = prevAttrs.src.overrideAttrs {outputHash = "sha256-gv6Y+VImdXICrqt2YDr4ROoL6xJSuRE1XyAasSM3dW4=";};
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
