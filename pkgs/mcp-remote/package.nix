{
  fetchFromGitHub,
  fetchPnpmDeps,
  lib,
  makeWrapper,
  nodejs,
  pnpm_10,
  pnpmConfigHook,
  stdenv,
}: let
  pnpm = pnpm_10;
in
  stdenv.mkDerivation (finalAttrs: {
    pname = "mcp-remote";
    version = "0.1.38";

    src = fetchFromGitHub {
      owner = "geelen";
      repo = "mcp-remote";
      tag = "v${finalAttrs.version}";
      hash = "sha256-+oNI2Uq7gW3sLzJS4ky2+BXhTmo44+WpcdYgieGPpmI=";
    };

    pnpmDeps = fetchPnpmDeps {
      inherit (finalAttrs) pname version src;
      inherit pnpm;
      fetcherVersion = 3;
      hash = "sha256-8aV/WRBrcezMb8HyRKW89v11MumgQnQwSBde5MZkzos=";
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

    installPhase = ''
      runHook preInstall

      pnpm prune --prod

      mkdir -p "$out/lib/mcp-remote"
      cp -r dist node_modules package.json "$out/lib/mcp-remote/"

      makeWrapper ${lib.getExe nodejs} "$out/bin/mcp-remote" \
        --add-flags "$out/lib/mcp-remote/dist/proxy.js"

      makeWrapper ${lib.getExe nodejs} "$out/bin/mcp-remote-client" \
        --add-flags "$out/lib/mcp-remote/dist/client.js"

      runHook postInstall
    '';

    meta = {
      description = "Remote proxy for Model Context Protocol stdio clients";
      homepage = "https://github.com/geelen/mcp-remote";
      license = lib.licenses.mit;
      mainProgram = "mcp-remote";
      platforms = lib.platforms.unix;
    };
  })
