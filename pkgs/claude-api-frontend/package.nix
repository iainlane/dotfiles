{
  callPackage,
  lib,
  makeWrapper,
  nodejs_24,
  openssl,
  pnpm_10,
}:
(callPackage ../build-support/pnpm-package.nix {}) {
  pname = "claude-api-frontend";
  directory = ./.;
  pnpm = pnpm_10;
  dependencyHashes = {
    aarch64-darwin = "sha256-zJmmm2OrWhyGQ9skYpGM4k688UcMUwRDcgYA7j6cCWk=";
    aarch64-linux = "sha256-zJmmm2OrWhyGQ9skYpGM4k688UcMUwRDcgYA7j6cCWk=";
    x86_64-linux = "sha256-zJmmm2OrWhyGQ9skYpGM4k688UcMUwRDcgYA7j6cCWk=";
  };
  packageRoot = "lib/claude-api-frontend";
  npmTarball = false;
  shellPackages = [openssl];

  nativeBuildInputs = [makeWrapper openssl];
  __darwinAllowLocalNetworking = true;

  installPhase = ''
    runHook preInstall
    checkModules="$TMPDIR/frontend-check-node-modules"
    mv node_modules "$checkModules"
    CI=true pnpm install --prod --offline --frozen-lockfile --ignore-scripts
    mkdir -p "$out/$packageRoot"
    cp -r src package.json node_modules "$out/$packageRoot/"
    find "$out/$packageRoot" -type f \( -name .modules.yaml -o -name .pnpm-workspace-state-v1.json \) -delete
    makeWrapper ${lib.getExe nodejs_24} "$out/bin/claude-api-frontend" \
      --prefix PATH : ${lib.makeBinPath [openssl]} \
      --add-flags "$out/$packageRoot/src/cli.ts"
    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    for cache in .vite .vitest-cache; do
      if test -e "$out/$packageRoot/node_modules/$cache"; then
        printf 'Test cache installed: %s\n' "$cache" >&2
        exit 1
      fi
    done
    rm -rf node_modules
    mv "$checkModules" node_modules
    CLAUDE_API_FRONTEND_PROGRAM="$out/bin/claude-api-frontend" \
      pnpm exec vitest run test/installed.test.ts
    runHook postInstallCheck
  '';

  meta = {
    description = "Loopback Claude API request conversion before TeamClaude";
    mainProgram = "claude-api-frontend";
    platforms = lib.platforms.unix;
  };
}
