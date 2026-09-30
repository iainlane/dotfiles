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
  version = "1.1.22";

  src = fetchFromGitHub {
    owner = "KarpelesLab";
    repo = "teamclaude";
    tag = "v${finalAttrs.version}";
    hash = "sha256-97RTFysHpQ3pUv4Q1eHdknqywzDQ6Ym/BjM6s+KmfCs=";
  };

  nativeBuildInputs = [makeWrapper];

  dontBuild = true;

  # Inside the Darwin sandbox each Node process that the tests spawn takes
  # several seconds to start. When the test files run in parallel, the CLI
  # tests exceed their hard-coded 10-second limits.
  doCheck = stdenvNoCC.hostPlatform.isLinux;

  nativeCheckInputs = [nodejs];

  checkPhase = ''
    runHook preCheck

    HOME="$TMPDIR" node --test --test-timeout=120000

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
