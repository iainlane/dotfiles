# To update: nix run .#update-teamclaude
{
  fetchFromGitHub,
  lib,
  libfaketime,
  makeWrapper,
  nodejs,
  stdenvNoCC,
  updaters,
}:
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "teamclaude";
  version = "1.1.26";

  src = fetchFromGitHub {
    owner = "KarpelesLab";
    repo = "teamclaude";
    tag = "v${finalAttrs.version}";
    hash = "sha256-BlYAlg5GKRDp/+6b66bPIRAGyyJaQyAC5FYKGZR2ON4=";
  };

  nativeBuildInputs = [makeWrapper];

  dontBuild = true;

  doCheck = true;

  nativeCheckInputs = [libfaketime nodejs];

  __darwinAllowLocalNetworking = true;

  checkPhase = ''
    runHook preCheck

    HOME="$TMPDIR" TZ=UTC FAKETIME_DONT_FAKE_MONOTONIC=1 \
      faketime -f '@2026-10-04 00:00:00' \
      node --test --test-timeout=120000 ${lib.optionalString stdenvNoCC.hostPlatform.isDarwin "--test-concurrency=1"}

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

  passthru.updateScript = updaters.mkNixUpdateUpdater {attr = "teamclaude";};

  meta = {
    description = "Multi-account proxy that rotates Claude Code between subscription accounts on quota";
    homepage = "https://github.com/KarpelesLab/teamclaude";
    license = lib.licenses.mit;
    mainProgram = "teamclaude";
    platforms = lib.platforms.unix;
  };
})
