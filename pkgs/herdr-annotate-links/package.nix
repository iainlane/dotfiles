{
  bash,
  coreutils,
  gawk,
  gnused,
  herdr-annotate,
  lib,
  makeWrapper,
  stdenvNoCC,
}:
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "herdr-annotate-links";
  inherit (herdr-annotate) version src;

  nativeBuildInputs = [makeWrapper];
  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    pluginRoot="$out/share/herdr/plugins/herdr-annotate-links"
    install -Dm644 links/herdr-plugin.toml "$pluginRoot/herdr-plugin.toml"
    install -Dm755 links/open-link.sh "$pluginRoot/open-link.sh"
    install -Dm644 LICENSE -t "$pluginRoot"

    patchShebangs "$pluginRoot/open-link.sh"
    wrapProgram "$pluginRoot/open-link.sh" \
      --prefix PATH : ${lib.makeBinPath [coreutils gawk gnused]}

    substituteInPlace "$pluginRoot/herdr-plugin.toml" \
      --replace-fail 'command = ["bash", "open-link.sh"]' \
        "command = [\"${lib.getExe bash}\", \"$pluginRoot/open-link.sh\"]"

    runHook postInstall
  '';

  passthru = {
    pluginRoot = "${finalAttrs.finalPackage}/share/herdr/plugins/herdr-annotate-links";
    updateScript = null;
  };

  meta = {
    description = "Herdr Annotate add-on for reviewing Ctrl-clicked Markdown file links";
    homepage = "https://github.com/plannotator/herdr-annotate";
    license = lib.licenses.mit;
    inherit (herdr-annotate.meta) platforms;
  };
})
