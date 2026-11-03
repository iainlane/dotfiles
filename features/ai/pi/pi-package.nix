{
  inputs,
  system,
}: let
  inherit (inputs.nixpkgs) lib;
  base = inputs.llm-agents.packages.${system}.pi;
  sdkPackageRoot = "libexec/pi-sdk";
in
  base.overrideAttrs (old: {
    patches = (old.patches or []) ++ [./native-call-label.patch ./native-message-errors.patch];
    buildInputs =
      (old.buildInputs or [])
      ++ lib.optionals base.stdenv.hostPlatform.isLinux [base.stdenv.cc.cc.lib];
    outputs = (old.outputs or ["out"]) ++ ["sdk"];
    preInstall = ''
      mkdir -p "$sdk/${sdkPackageRoot}"
      cp -a package.json package-lock.json README.md CHANGELOG.md dist docs examples node_modules "$sdk/${sdkPackageRoot}/"
      ${old.preInstall or ""}
    '';
    passthru = (old.passthru or {}) // {inherit sdkPackageRoot;};
  })
