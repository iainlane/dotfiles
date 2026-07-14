# To update: nix run .#update-melange
{
  melange,
  updaters,
}:
melange.overrideAttrs (_finalAttrs: prevAttrs: {
  version = "0.56.2";
  src = prevAttrs.src.overrideAttrs {outputHash = "sha256-wlg4St2+LePqNMvcLaTOKtkOngx9wZQ2K0kfmDKp6wM=";};
  vendorHash = "sha256-lzVHSb8gpitjVfEOEYbWbbNv8A783nW631hpIuS1OSY=";

  passthru =
    (prevAttrs.passthru or {})
    // {
      updateScript = updaters.mkNixUpdateUpdater {
        attr = "melange";
        extraFlags = ["--use-github-releases"];
      };
    };
})
