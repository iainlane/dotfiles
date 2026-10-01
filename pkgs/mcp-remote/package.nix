# To update: nix run .#update-mcp-remote
{
  fetchFromGitHub,
  fetchPnpmDeps,
  lib,
  makeWrapper,
  husky,
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
    version = "0.14.3";

    src = fetchFromGitHub {
      owner = "punkpeye";
      repo = "mcp-remote";
      tag = "v${finalAttrs.version}";
      hash = "sha256-oRsutl0pvt+9IsQ86lr1UgbU7TKJHVoLDLLagutEy58=";
    };

    pnpmDeps = fetchPnpmDeps {
      inherit (finalAttrs) pname version src;
      inherit pnpm;
      fetcherVersion = 3;
      hash = "sha256-KPasWdU7aLVWOO+hdGlhYsylgJRD5Xses0wL1s6yt8w=";
    };

    nativeBuildInputs = [
      husky
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

    installPhase = ''
      runHook preInstall

      pnpm prune --prod

      # pnpm writes metadata files containing timestamps and the build
      # directory, and its .bin shims hard-code NODE_PATH under the build
      # directory. This makes the output unreproducible, so delete them. The
      # .bin shims are not needed because we wrap the main scripts.
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
