# To update: nix run .#update-melange
{
  melange,
  updaters,
}:
melange.overrideAttrs (_finalAttrs: prevAttrs: {
  version = "0.56.5";
  src = prevAttrs.src.overrideAttrs {outputHash = "sha256-QEk74JLKNmjvN8Yu1Kx3APrV17CyBProsEjLeoBOgms=";};
  vendorHash = "sha256-M0eIwpAGuYzVlEfRblES7MJovyi6cI1eTr/LXMA5vN4=";

  passthru =
    (prevAttrs.passthru or {})
    // {
      updateScript = updaters.mkNixUpdateUpdater {
        attr = "melange";
        extraFlags = ["--use-github-releases"];
      };
    };
})
