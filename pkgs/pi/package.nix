{
  callPackage,
  lib,
  stdenv,
  upstreamPackage,
}: let
  npmPackages = import ../../lib/npm-packages.nix {inherit lib;};
  npmName = "@earendil-works/pi-coding-agent";
  sdkPackageRoot = "libexec/pi-sdk";
in
  upstreamPackage.overrideAttrs (finalAttrs: old: {
    patches = (old.patches or []) ++ [./native-call-label.patch ./native-message-errors.patch];
    buildInputs = (old.buildInputs or []) ++ lib.optionals stdenv.hostPlatform.isLinux [stdenv.cc.cc.lib];
    outputs = (old.outputs or ["out"]) ++ ["sdk"];
    preInstall = ''
      mkdir -p "$sdk/${sdkPackageRoot}"
      cp -a package.json package-lock.json README.md CHANGELOG.md dist docs examples node_modules "$sdk/${sdkPackageRoot}/"
      ${old.preInstall or ""}
    '';
    passthru =
      (old.passthru or {})
      // {
        updateScript = null;
        maintenance = {
          source = "input";
          inputs = ["llm-agents"];
        };

        npmTarball = callPackage ../build-support/npm-tarball.nix {} {
          name = npmName;
          inherit (finalAttrs) version;
          directory = "${finalAttrs.finalPackage.sdk}/${sdkPackageRoot}";
        };
      };
    meta =
      old.meta
      // {
        identifiers.purlParts = npmPackages.purlParts {
          name = npmName;
          inherit (finalAttrs) version;
        };
      };
  })
