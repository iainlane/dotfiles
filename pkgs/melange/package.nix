# To update: nix run .#update-melange
{
  melange,
  updaters,
}:
melange.overrideAttrs (_finalAttrs: prevAttrs: {
  version = "0.56.4";
  src = prevAttrs.src.overrideAttrs {outputHash = "sha256-ImcZhsJiBvsADPJJnzWuckCyiPiK00rMdnu1naU6gS4=";};
  vendorHash = "sha256-2uCWNn42CNeHgiFP2dYaZl0j5waSL/qM33mpav2XP/U=";

  passthru =
    (prevAttrs.passthru or {})
    // {
      updateScript = updaters.mkNixUpdateUpdater {
        attr = "melange";
        extraFlags = ["--use-github-releases"];
      };
    };
})
