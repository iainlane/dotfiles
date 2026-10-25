{
  callPackage,
  coreutils,
  jq,
  lib,
  makeWrapper,
  nodejs_24,
  teamclaude,
}:
(callPackage ../../../../../lib/build-typescript-package.nix {}) {
  pname = "teamclaude-provision";
  version = "0.1.0";
  directory = ./.;
  nodejs = nodejs_24;
  npmFlags = ["--ignore-scripts"];
  nativeBuildInputs = [makeWrapper];
  nativeInstallCheckInputs = [jq coreutils];
  dontNpmBuild = true;
  dontNpmInstall = true;
  dontNpmPrune = true;
  doCheck = true;

  checkPhase = ''
    runHook preCheck
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    npm run check
    runHook postCheck
  '';
  installPhase = ''
    runHook preInstall
    npm prune --omit=dev --ignore-scripts --offline
    mkdir -p "$out/lib/teamclaude-provision"
    cp -r provision.ts package.json node_modules "$out/lib/teamclaude-provision/"
    makeWrapper ${lib.getExe nodejs_24} "$out/bin/teamclaude-provision" \
      --add-flags "$out/lib/teamclaude-provision/provision.ts"
    runHook postInstall
  '';
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    export TEAMCLAUDE_CONFIG="$TMPDIR/installed-teamclaude.json"
    export TEAMROUTER_CONFIG="$TEAMCLAUDE_CONFIG"
    echo '{"accounts":[]}' > "$TEAMCLAUDE_CONFIG"
    echo first-key > "$TMPDIR/key"
    jq -n --arg key "$TMPDIR/key" \
      '{settings:{},apiKeyAccounts:{fallback:{apiKeyFile:$key,priority:100}}}' \
      > "$TMPDIR/provision.json"
    PATH="" "$out/bin/teamclaude-provision" \
      ${teamclaude}/lib/teamclaude/src/config.js "$TMPDIR/provision.json"
    id=$(jq -r '.accounts[0].id' "$TEAMCLAUDE_CONFIG")
    test -n "$id" && test "$id" != null
    echo rotated-key > "$TMPDIR/key"
    PATH="" "$out/bin/teamclaude-provision" \
      ${teamclaude}/lib/teamclaude/src/config.js "$TMPDIR/provision.json"
    jq -e --arg id "$id" \
      '.accounts[0] | .id == $id and .apiKey == "rotated-key"' "$TEAMCLAUDE_CONFIG"
    test "$(stat -c %a "$TEAMCLAUDE_CONFIG")" = 600
    runHook postInstallCheck
  '';
  meta.mainProgram = "teamclaude-provision";
}
