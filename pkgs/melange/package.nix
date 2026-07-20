# To update: nix run .#update-melange
{
  melange,
  updaters,
}:
melange.overrideAttrs (_finalAttrs: prevAttrs: {
  version = "0.56.3";
  src = prevAttrs.src.overrideAttrs {outputHash = "sha256-rA4Y9eBgyRVY6yIvK5PKPrE8DqG+rKVNInVoFZnurMw=";};
  vendorHash = "sha256-3X22yGTTq9pbaeqjYhnW/M0LFIrzaEpgcsp6lpbBkG8=";

  passthru =
    (prevAttrs.passthru or {})
    // {
      updateScript = updaters.mkNixUpdateUpdater {
        attr = "melange";
        extraFlags = ["--use-github-releases"];
      };
    };
})
