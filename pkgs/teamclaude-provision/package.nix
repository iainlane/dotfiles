{
  callPackage,
  coreutils,
  jq,
  lib,
  makeWrapper,
  nodejs_24,
  pnpm_10,
  teamclaude,
}:
(callPackage ../build-support/pnpm-package.nix {}) {
  pname = "teamclaude-provision";
  directory = ./.;
  pnpm = pnpm_10;
  dependencyHashes = {
    aarch64-darwin = "sha256-el+DFXV+sGZJSS4wtUpvAf1ofA8OJZZHwQVp0bKk/Og=";
    aarch64-linux = "sha256-el+DFXV+sGZJSS4wtUpvAf1ofA8OJZZHwQVp0bKk/Og=";
    x86_64-linux = "sha256-el+DFXV+sGZJSS4wtUpvAf1ofA8OJZZHwQVp0bKk/Og=";
  };

  # Node does not strip types from TypeScript files under node_modules.
  packageRoot = "lib/teamclaude-provision";

  nativeBuildInputs = [makeWrapper];
  nativeInstallCheckInputs = [jq coreutils];
  preCheck = ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
  '';
  postInstall = ''
    makeWrapper ${lib.getExe nodejs_24} "$out/bin/teamclaude-provision" \
      --add-flags "$out/$packageRoot/provision.ts"
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
