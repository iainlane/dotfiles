{
  fetchFromGitHub,
  lib,
  python3,
  stdenvNoCC,
  updaters,
}:
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "herdr-disp-model";
  # The repository has no release tags, so the package builds a commit from
  # `main`. The version is the `version` field of that commit's manifest,
  # followed by the commit date.
  version = "0-unstable-2026-09-19";

  src = fetchFromGitHub {
    owner = "pdalinis";
    repo = "herdr-disp-model";
    rev = "48a4b9490f71d2d818db145564ca6c31fc2805fa";
    hash = "sha256-6kscnaioPfxexi1Mdz3ySJnw0P3ICAJRI4k1rU5HAWc=";
  };

  # Unpatched, the plugin replaces the agent's name in the Herdr sidebar with a
  # label such as `claude - claude-opus-5-5 - high`. The patch removes that
  # label from the Claude Code, Codex and Pi adapters. The `agent` token then
  # shows the plain name, and the sidebar shows the model and effort through
  # the `$model` and `$effort` tokens.
  patches = [./plain-agent-name.patch];

  dontConfigure = true;
  dontBuild = true;

  # The manifest's commands run `python3` from PATH, and the Herdr server's
  # PATH does not always contain it. The install phase points them at the
  # Python in the Nix store.
  installPhase = ''
    runHook preInstall

    pluginRoot="$out/share/herdr/plugins/herdr-disp-model"
    install -Dm644 herdr-plugin.toml "$pluginRoot/herdr-plugin.toml"
    install -Dm755 src/model_display.py "$pluginRoot/src/model_display.py"
    install -Dm644 adapters/pi-model-display.ts "$pluginRoot/adapters/pi-model-display.ts"
    install -Dm644 LICENSE README.md -t "$pluginRoot"

    substituteInPlace "$pluginRoot/herdr-plugin.toml" \
      --replace-fail 'command = ["python3",' 'command = ["${lib.getExe python3}",'

    runHook postInstall
  '';

  doInstallCheck = true;

  installCheckPhase = ''
    runHook preInstallCheck

    if grep -q '"python3"' "$out/share/herdr/plugins/herdr-disp-model/herdr-plugin.toml"; then
      echo "a manifest command still runs python3 from PATH" >&2
      exit 1
    fi

    HOME="$TMPDIR" ${lib.getExe python3} -I -m unittest discover -s tests

    runHook postInstallCheck
  '';

  passthru = let
    pluginRoot = "${finalAttrs.finalPackage}/share/herdr/plugins/herdr-disp-model";
  in {
    inherit pluginRoot;

    # The command that the Claude Code and Codex hooks run, with `claude-hook`
    # or `codex-hook` as its argument. The script finds the Herdr binary
    # through `HERDR_BIN_PATH`, which Herdr sets in every pane.
    hookCommand = "${lib.getExe python3} ${pluginRoot}/src/model_display.py";

    piExtension = "${pluginRoot}/adapters/pi-model-display.ts";

    updateScript = updaters.mkNixUpdateUpdater {
      attr = "herdr-disp-model";
      extraFlags = ["--version=branch=main"];
    };
  };

  meta = {
    description = "Herdr plugin that shows the model and reasoning effort of each agent";
    homepage = "https://github.com/pdalinis/herdr-disp-model";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
})
