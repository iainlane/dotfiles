# To update: nix run .#update-teamclaude
{
  fetchFromGitHub,
  lib,
  makeWrapper,
  nodejs,
  stdenvNoCC,
  updaters,
}:
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "teamclaude";
  version = "1.1.30";

  src = fetchFromGitHub {
    owner = "KarpelesLab";
    repo = "teamclaude";
    tag = "v${finalAttrs.version}";
    hash = "sha256-oSbOCR8iWog30pC+VgXk4HE6pA/2B+6ptAe1eCprRpw=";
  };

  nativeBuildInputs = [makeWrapper];

  dontBuild = true;

  doCheck = true;

  nativeCheckInputs = [nodejs];

  __darwinAllowLocalNetworking = true;

  checkPhase = ''
    runHook preCheck

    HOME="$TMPDIR" TZ=UTC node --test --test-timeout=120000 ${lib.optionalString stdenvNoCC.hostPlatform.isDarwin "--test-concurrency=1"}

    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/lib/teamclaude"
    cp -r package.json src "$out/lib/teamclaude/"

    # TeamClaude updates itself with `npm install -g`, which cannot replace a
    # store path.
    makeWrapper ${lib.getExe nodejs} "$out/bin/teamclaude" \
      --add-flags "$out/lib/teamclaude/src/index.js" \
      --set-default TEAMCLAUDE_DISABLE_AUTOUPDATE 1

    runHook postInstall
  '';

  passthru = {
    maintenance.source = "release";
    updateScript = updaters.mkNixUpdateUpdater {attr = "teamclaude";};
  };

  meta = {
    description = "Multi-account proxy that rotates Claude Code between subscription accounts on quota";
    homepage = "https://github.com/KarpelesLab/teamclaude";
    license = lib.licenses.mit;
    mainProgram = "teamclaude";
    platforms = lib.platforms.unix;
  };
})
