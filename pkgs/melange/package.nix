# To update: nix run .#update-melange
{
  melange,
  updaters,
}:
melange.overrideAttrs (_finalAttrs: prevAttrs: {
  version = "0.56.1";
  src = prevAttrs.src.overrideAttrs {outputHash = "sha256-4TR0MlPcaSwVzGLHQvlklhDjZR8hrIB6FP5GFcHp8vA=";};
  vendorHash = "sha256-ZkUbvu0ko9HCurD6Nyl79Z7+LEMKOjpQjXaHXYVgqfI=";

  passthru =
    (prevAttrs.passthru or {})
    // {
      updateScript = updaters.mkNixUpdateUpdater {
        attr = "melange";
        extraFlags = ["--use-github-releases"];
      };
    };
})
