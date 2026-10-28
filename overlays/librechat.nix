_: final: prev: let
  baseVersion = "0.8.9-rc1";
  revision = "3dd44caff7c7d294eb234c8a17404fb6790ee720";
in {
  librechat = prev.librechat.overrideAttrs (finalAttrs: previousAttrs: {
    version = "${baseVersion}-unstable-2026-10-28";
    src = final.fetchFromGitHub {
      owner = "iainlane";
      repo = "LibreChat";
      rev = revision;
      hash = "sha256-8htbZvvO5A/ePSRgAHOAea+RCTP7rmZKOrTFn1T0bXc=";
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
