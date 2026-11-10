# To update: nix run .#update-teamclaude
{
  fetchFromGitHub,
  lib,
  libfaketime,
  makeWrapper,
  nodejs,
  stdenvNoCC,
  updaters,
  gh,
  python3,
  writeShellApplication,
}:
stdenvNoCC.mkDerivation {
  pname = "teamclaude";
  version = "1.1.26-unstable-2026-10-30";

  src = fetchFromGitHub {
    owner = "iainlane";
    repo = "teamclaude";
    rev = "654fd97303f927078cafafdbf980f0c11c5af61e";
    hash = "sha256-aH+RFzSbS5boQlHv1L6b4Jn1Yx4Sy9oCT7RCWhTOTn8=";
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

  passthru = {
    maintenance = {
      source = "pin";
      reason = "The fork includes subscription routing fixes from PR #621.";
    };
    updateScript = writeShellApplication {
      name = "update-teamclaude";
      runtimeInputs = [gh python3];
      text = ''exec python3 ${./update.py} "$@"'';
    };
    tests.updater = updaters.mkPythonUpdaterTest {
      pname = "teamclaude";
      script = ./update.py;
      test = ./test_update.py;
    };
  };

  meta = {
    description = "Multi-account proxy that rotates Claude Code between subscription accounts on quota";
    homepage = "https://github.com/KarpelesLab/teamclaude";
    license = lib.licenses.mit;
    mainProgram = "teamclaude";
    platforms = lib.platforms.unix;
  };
}
