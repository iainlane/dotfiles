_: final: prev: let
  baseVersion = "0.8.9-rc1";
  revision = "9c9930951a7177f158d0ecb352ff4230850c8a5f";
in {
  librechat = prev.librechat.overrideAttrs (finalAttrs: previousAttrs: {
    version = "${baseVersion}-unstable-2026-10-29";
    src = final.fetchFromGitHub {
      owner = "iainlane";
      repo = "LibreChat";
      rev = revision;
      hash = "sha256-yg8VupJCV33W8/henXPeTFo23RnGT9Ug47Zekx9Ahx4=";
    };
    npmDepsHash = "sha256-0f0VaGBGxz/tI+8B4wSCGVyzlMH1yDDv9K0fWvDpjZ4=";
    npmDeps = previousAttrs.npmDeps.overrideAttrs {
      name = "librechat-${baseVersion}-npm-deps";
      inherit (finalAttrs) src;
      outputHash = finalAttrs.npmDepsHash;
    };
    preFixup =
      previousAttrs.preFixup
      + ''
        mkdir -p "$out/lib/node_modules/LibreChat/vendor"
        cp -R vendor/code "$out/lib/node_modules/LibreChat/vendor/"
      '';
    passthru = previousAttrs.passthru // {updateScript = null;};
    meta =
      previousAttrs.meta
      // {
        homepage = "https://github.com/iainlane/LibreChat";
        changelog = "https://github.com/iainlane/LibreChat/compare/v${baseVersion}...${revision}";
      };
  });
}
