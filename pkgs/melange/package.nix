# To update: nix run .#update-melange
{
  melange,
  updaters,
}:
melange.overrideAttrs (_finalAttrs: prevAttrs: {
  version = "0.59.1";
  src = prevAttrs.src.overrideAttrs {outputHash = "sha256-i6JneJj/zg3lyVMqi1ojOgSzBHAIWmGBzgEpvIXW9r8=";};
  vendorHash = "sha256-mV4n+6RIf81abnYCaPevgqJfhkC7UMSRnn8JJQHTe4w=";

  passthru =
    (prevAttrs.passthru or {})
    // {
      updateScript = updaters.mkNixUpdateUpdater {
        attr = "melange";
        extraFlags = ["--use-github-releases"];
      };
    };
})
