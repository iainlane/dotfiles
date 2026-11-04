{
  lib,
  stdenv,
  upstreamPi,
}: let
  sdkPackageRoot = "libexec/pi-sdk";
in
  upstreamPi.overrideAttrs (old: {
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
        inherit sdkPackageRoot;
        setupNativeSdk = ./setup-native-sdk.bash;
        updateScript = null;
      };
  })
