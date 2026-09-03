# To update: nix run .#update-mcp-remote
{
  fetchFromGitHub,
  fetchPnpmDeps,
  lib,
  makeWrapper,
  nodejs,
  pnpm_10,
  pnpmConfigHook,
  stdenv,
  updaters,
}: let
  pnpm = pnpm_10;
in
  stdenv.mkDerivation (finalAttrs: {
    pname = "mcp-remote";
    version = "0.8.3";

    src = fetchFromGitHub {
      owner = "geelen";
      repo = "mcp-remote";
      tag = "v${finalAttrs.version}";
      hash = "sha256-pnCHGSZRuv67LmnvzVDJZHRpSyiaoY1mNX5mJyZ/2AA=";
    };

    patches = [./optional-oauth-scope.patch];

    pnpmDeps = fetchPnpmDeps {
      inherit (finalAttrs) pname version src;
      inherit pnpm;
      fetcherVersion = 3;
      hash = "sha256-79D8e+JM9uZq29Xze3Q8sdAD2ya0GirIAHd2JR2ljpU=";
    };

    nativeBuildInputs = [
      makeWrapper
      nodejs
      pnpm
      pnpmConfigHook
    ];

    buildPhase = ''
      runHook preBuild

      pnpm build

      runHook postBuild
    '';

    doCheck = true;

    checkPhase = ''
      runHook preCheck

      # vitest's worker RPC has a fixed 60-second timeout that flakes when
      # the build machine is under load (vitest-dev/vitest#4106). The suite
      # runs in under a second, so parallel workers buy nothing.
      pnpm test:unit -- --no-file-parallelism

      runHook postCheck
    '';

    installPhase = ''
      runHook preInstall

      pnpm prune --prod

      # pnpm writes metadata files containing timestamps and the build
      # directory, and its .bin shims hard-code NODE_PATH under the build
      # directory. None of it works or is needed at runtime, and it makes
      # the output unreproducible.
      rm node_modules/.modules.yaml node_modules/.pnpm-workspace-state-v1.json
      find node_modules -type d -name .bin -exec rm -r {} +

      mkdir -p "$out/lib/mcp-remote"
      cp -r dist node_modules package.json "$out/lib/mcp-remote/"

      makeWrapper ${lib.getExe nodejs} "$out/bin/mcp-remote" \
        --add-flags "$out/lib/mcp-remote/dist/proxy.js"

      makeWrapper ${lib.getExe nodejs} "$out/bin/mcp-remote-client" \
        --add-flags "$out/lib/mcp-remote/dist/client.js"

      runHook postInstall
    '';

    passthru.updateScript = updaters.mkNixUpdateUpdater {attr = "mcp-remote";};

    meta = {
      description = "Remote proxy for Model Context Protocol stdio clients";
      homepage = "https://github.com/geelen/mcp-remote";
      license = lib.licenses.mit;
      mainProgram = "mcp-remote";
      platforms = lib.platforms.unix;
    };
  })
