_: final: prev: let
  baseVersion = "0.8.9-rc1";
  revision = "d4f684b162cfdf6e86a948ef6ad36bba7aa2b21e";
in {
  librechat = prev.librechat.overrideAttrs (finalAttrs: previousAttrs: {
    version = "${baseVersion}-unstable-2026-11-03";
    src = final.fetchFromGitHub {
      owner = "iainlane";
      repo = "LibreChat";
      rev = revision;
      hash = "sha256-eKozA1Rq3MTmVeYunRxxJMVFjYyu9dQBsjOSI/4bfbk=";
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
