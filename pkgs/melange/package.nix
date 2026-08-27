# To update: nix run .#update-melange
{
  melange,
  updaters,
}:
melange.overrideAttrs (_finalAttrs: prevAttrs: {
  version = "0.59.2";
  src = prevAttrs.src.overrideAttrs {outputHash = "sha256-dwY1AcXT+BKff0snfCQqfygd0mW9zVmrLbDn5gr4mbM=";};
  vendorHash = "sha256-CPOWqFdJa5wRC0tFKdwxdGT6QtMSVdColUjrAwXrm6o=";

  passthru =
    (prevAttrs.passthru or {})
    // {
      updateScript = updaters.mkNixUpdateUpdater {
        attr = "melange";
        extraFlags = ["--use-github-releases"];
      };
    };
})
