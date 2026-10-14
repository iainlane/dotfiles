{
  fetchFromGitHub,
  lib,
  python3,
  stdenvNoCC,
  updaters,
}:
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "herdr-ctx-bar";
  version = "0.1.0";

  src = fetchFromGitHub {
    owner = "pdalinis";
    repo = "herdr-ctx-bar";
    tag = "v${finalAttrs.version}";
    hash = "sha256-jD5XGvWZyf5AYKw9dMSny4lPt8BEhEBVgv0ub783zhg=";
  };

  dontConfigure = true;
  dontBuild = true;

  # The manifest's commands run `python3` from PATH, and the Herdr server's
  # PATH does not always contain it. The install phase points them at the
  # Python in the Nix store.
  installPhase = ''
    runHook preInstall

    pluginRoot="$out/share/herdr/plugins/herdr-ctx-bar"
    install -Dm644 herdr-plugin.toml "$pluginRoot/herdr-plugin.toml"
    install -Dm755 bin/ctx_bar.py "$pluginRoot/bin/ctx_bar.py"
    install -Dm644 LICENSE README.md -t "$pluginRoot"

    substituteInPlace "$pluginRoot/herdr-plugin.toml" \
      --replace-fail 'command = ["python3",' 'command = ["${lib.getExe python3}",'

    runHook postInstall
  '';

  doInstallCheck = true;

  installCheckPhase = ''
    runHook preInstallCheck

    manifest="$out/share/herdr/plugins/herdr-ctx-bar/herdr-plugin.toml"

    if ! grep -qx 'version = "${finalAttrs.version}"' "$manifest"; then
      echo "the manifest's version is not ${finalAttrs.version}" >&2
      exit 1
    fi

    if grep -q '"python3"' "$manifest"; then
      echo "a manifest command still runs python3 from PATH" >&2
      exit 1
    fi

    HOME="$TMPDIR" ${lib.getExe python3} -I -m unittest discover -s tests

    runHook postInstallCheck
  '';

  passthru = {
    pluginRoot = "${finalAttrs.finalPackage}/share/herdr/plugins/herdr-ctx-bar";
    updateScript = updaters.mkNixUpdateUpdater {attr = "herdr-ctx-bar";};
  };

  meta = {
    description = "Herdr plugin that shows a colour-coded context usage bar for each agent";
    homepage = "https://github.com/pdalinis/herdr-ctx-bar";
    changelog = "https://github.com/pdalinis/herdr-ctx-bar/releases/tag/v${finalAttrs.version}";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
})
